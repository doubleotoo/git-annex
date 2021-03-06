{- git-annex assistant webapp configurator for editing existing repos
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE CPP, QuasiQuotes, TemplateHaskell, OverloadedStrings #-}

module Assistant.WebApp.Configurators.Edit where

import Assistant.WebApp.Common
import Assistant.WebApp.Utility
import Assistant.DaemonStatus
import Assistant.MakeRemote (uniqueRemoteName)
import Assistant.WebApp.Configurators.XMPP (xmppNeeded)
import Assistant.ScanRemotes
import qualified Assistant.WebApp.Configurators.AWS as AWS
import qualified Assistant.WebApp.Configurators.IA as IA
#ifdef WITH_S3
import qualified Remote.S3 as S3
#endif
import qualified Remote
import qualified Types.Remote as Remote
import qualified Remote.List as Remote
import Logs.UUID
import Logs.Group
import Logs.PreferredContent
import Logs.Remote
import Types.StandardGroups
import qualified Git
import qualified Git.Command
import qualified Git.Config
import qualified Annex
import Git.Remote

import qualified Data.Text as T
import qualified Data.Map as M
import qualified Data.Set as S

data RepoGroup = RepoGroupCustom String | RepoGroupStandard StandardGroup
	deriving (Show, Eq)

data RepoConfig = RepoConfig
	{ repoName :: Text
	, repoDescription :: Maybe Text
	, repoGroup :: RepoGroup
	, repoAssociatedDirectory :: Maybe Text
	, repoSyncable :: Bool
	}
	deriving (Show)

getRepoConfig :: UUID -> Maybe Remote -> Annex RepoConfig
getRepoConfig uuid mremote = do
	groups <- lookupGroups uuid
	remoteconfig <- M.lookup uuid <$> readRemoteLog
	let (repogroup, associateddirectory) = case getStandardGroup groups of
		Nothing -> (RepoGroupCustom $ unwords $ S.toList groups, Nothing)
		Just g -> (RepoGroupStandard g, associatedDirectory remoteconfig g)
	
	description <- maybe Nothing (Just . T.pack) . M.lookup uuid <$> uuidMap

	syncable <- case mremote of
		Just r -> return $ remoteAnnexSync $ Remote.gitconfig r
		Nothing -> annexAutoCommit <$> Annex.getGitConfig

	return $ RepoConfig
		(T.pack $ maybe "here" Remote.name mremote)
		description
		repogroup
		(T.pack <$> associateddirectory)
		syncable
		
setRepoConfig :: UUID -> Maybe Remote -> RepoConfig -> RepoConfig -> Handler ()
setRepoConfig uuid mremote oldc newc = do
	when descriptionChanged $ liftAnnex $ do
		maybe noop (describeUUID uuid . T.unpack) (repoDescription newc)
		void uuidMapLoad
	when nameChanged $ do
		liftAnnex $ do
			name <- fromRepo $ uniqueRemoteName (legalName newc) 0
			{- git remote rename expects there to be a
			 - remote.<name>.fetch, and exits nonzero if
			 - there's not. Special remotes don't normally
			 - have that, and don't use it. Temporarily add
			 - it if it's missing. -}
			let remotefetch = "remote." ++ T.unpack (repoName oldc) ++ ".fetch"
			needfetch <- isNothing <$> fromRepo (Git.Config.getMaybe remotefetch)
			when needfetch $
				inRepo $ Git.Command.run
					[Param "config", Param remotefetch, Param ""]
			inRepo $ Git.Command.run
				[ Param "remote"
				, Param "rename"
				, Param $ T.unpack $ repoName oldc
				, Param name
				]
			void $ Remote.remoteListRefresh
		liftAssistant updateSyncRemotes
	when associatedDirectoryChanged $ case repoAssociatedDirectory newc of
		Nothing -> noop
		Just t
			| T.null t -> noop
			| otherwise -> liftAnnex $ do
				let dir = takeBaseName $ T.unpack t
				m <- readRemoteLog
				case M.lookup uuid m of
					Nothing -> noop
					Just remoteconfig -> configSet uuid $
						M.insert "preferreddir" dir remoteconfig
	when groupChanged $ do
		liftAnnex $ case repoGroup newc of
			RepoGroupStandard g -> setStandardGroup uuid g
			RepoGroupCustom s -> groupSet uuid $ S.fromList $ words s
		{- Enabling syncing will cause a scan,
		 - so avoid queueing a duplicate scan. -}
		when (repoSyncable newc && not syncableChanged) $ liftAssistant $
			case mremote of
				Just remote -> do
					addScanRemotes True [remote]
				Nothing -> do
					addScanRemotes True
						=<< syncDataRemotes <$> getDaemonStatus
	when syncableChanged $
		changeSyncable mremote (repoSyncable newc)
  where
  	syncableChanged = repoSyncable oldc /= repoSyncable newc
	associatedDirectoryChanged = repoAssociatedDirectory oldc /= repoAssociatedDirectory newc
	groupChanged = repoGroup oldc /= repoGroup newc
	nameChanged = isJust mremote && legalName oldc /= legalName newc
	descriptionChanged = repoDescription oldc /= repoDescription newc

	legalName = makeLegalName . T.unpack . repoName

editRepositoryAForm :: Bool -> RepoConfig -> MkAForm RepoConfig
editRepositoryAForm ishere def = RepoConfig
	<$> areq (if ishere then readonlyTextField else textField)
		"Name" (Just $ repoName def)
	<*> aopt textField "Description" (Just $ repoDescription def)
	<*> areq (selectFieldList groups `withNote` help) "Repository group" (Just $ repoGroup def)
	<*> associateddirectory
	<*> areq checkBoxField "Syncing enabled" (Just $ repoSyncable def)
  where
	groups = customgroups ++ standardgroups
	standardgroups :: [(Text, RepoGroup)]
	standardgroups = map (\g -> (T.pack $ descStandardGroup g , RepoGroupStandard g))
		[minBound :: StandardGroup .. maxBound :: StandardGroup]
	customgroups :: [(Text, RepoGroup)]
	customgroups = case repoGroup def of
		RepoGroupCustom s -> [(T.pack s, RepoGroupCustom s)]
		_ -> []
	help = [whamlet|<a href="@{RepoGroupR}">What's this?</a>|]

	associateddirectory = case repoAssociatedDirectory def of
		Nothing -> aopt hiddenField "" Nothing
		Just d -> aopt textField "Associated directory" (Just $ Just d)

getEditRepositoryR :: UUID -> Handler RepHtml
getEditRepositoryR = postEditRepositoryR

postEditRepositoryR :: UUID -> Handler RepHtml
postEditRepositoryR = editForm False

getEditNewRepositoryR :: UUID -> Handler RepHtml
getEditNewRepositoryR = postEditNewRepositoryR

postEditNewRepositoryR :: UUID -> Handler RepHtml
postEditNewRepositoryR = editForm True

getEditNewCloudRepositoryR :: UUID -> Handler RepHtml
getEditNewCloudRepositoryR = postEditNewCloudRepositoryR

postEditNewCloudRepositoryR :: UUID -> Handler RepHtml
postEditNewCloudRepositoryR uuid = xmppNeeded >> editForm True uuid

editForm :: Bool -> UUID -> Handler RepHtml
editForm new uuid = page "Edit repository" (Just Configuration) $ do
	mremote <- liftAnnex $ Remote.remoteFromUUID uuid
	curr <- liftAnnex $ getRepoConfig uuid mremote
	liftAnnex $ checkAssociatedDirectory curr mremote
	((result, form), enctype) <- liftH $
		runFormPost $ renderBootstrap $ editRepositoryAForm (isNothing mremote) curr
	case result of
		FormSuccess input -> liftH $ do
			setRepoConfig uuid mremote curr input
			liftAnnex $ checkAssociatedDirectory input mremote
			redirect DashboardR
		_ -> do
			let istransfer = repoGroup curr == RepoGroupStandard TransferGroup
			repoInfo <- getRepoInfo mremote . M.lookup uuid
				<$> liftAnnex readRemoteLog
			$(widgetFile "configurators/editrepository")

{- Makes any directory associated with the repository. -}
checkAssociatedDirectory :: RepoConfig -> Maybe Remote -> Annex ()
checkAssociatedDirectory _ Nothing = noop
checkAssociatedDirectory cfg (Just r) = do
	repoconfig <- M.lookup (Remote.uuid r) <$> readRemoteLog
	case repoGroup cfg of
		RepoGroupStandard gr -> case associatedDirectory repoconfig gr of
			Just d -> inRepo $ \g ->
				createDirectoryIfMissing True $
					Git.repoPath g </> d
			Nothing -> noop
		_ -> noop

getRepoInfo :: Maybe Remote.Remote -> Maybe Remote.RemoteConfig -> Widget
getRepoInfo (Just r) (Just c) = case M.lookup "type" c of
	Just "S3"
#ifdef WITH_S3
		| S3.isIA c -> IA.getRepoInfo c
#endif
		| otherwise -> AWS.getRepoInfo c
	Just t
		| t /= "git" -> [whamlet|#{t} remote|]
	_ -> getGitRepoInfo $ Remote.repo r
getRepoInfo (Just r) _ = getRepoInfo (Just r) (Just $ Remote.config r)
getRepoInfo _ _ = [whamlet|git repository|]

getGitRepoInfo :: Git.Repo -> Widget
getGitRepoInfo r = do
	let loc = Git.repoLocation r
	[whamlet|git repository located at <tt>#{loc}</tt>|]
