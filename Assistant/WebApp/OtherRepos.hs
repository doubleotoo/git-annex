{- git-annex assistant webapp switching to other repos
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE QuasiQuotes, TemplateHaskell, OverloadedStrings #-}

module Assistant.WebApp.OtherRepos where

import Assistant.Common
import Assistant.WebApp.Types
import Assistant.WebApp.Page
import qualified Git.Construct
import qualified Git.Config
import Config.Files
import qualified Utility.Url as Url
import Utility.Yesod

import Yesod
import Control.Concurrent
import System.Process (cwd)

getRepositorySwitcherR :: Handler RepHtml
getRepositorySwitcherR = page "Switch repository" Nothing $ do
	repolist <- liftIO listOtherRepos
	$(widgetFile "control/repositoryswitcher")

listOtherRepos :: IO [(String, String)]
listOtherRepos = do
	dirs <- readAutoStartFile
	pwd <- getCurrentDirectory
	gooddirs <- filterM doesDirectoryExist $
		filter (\d -> not $ d `dirContains` pwd) dirs
	names <- mapM relHome gooddirs
	return $ sort $ zip names gooddirs

{- Starts up the assistant in the repository, and waits for it to create
 - a gitAnnexUrlFile. Waits for the assistant to be up and listening for
 - connections by testing the url. Once it's running, redirect to it.
 -}
getSwitchToRepositoryR :: FilePath -> Handler RepHtml
getSwitchToRepositoryR repo = do
	liftIO $ startAssistant repo
	liftIO $ addAutoStartFile repo -- make this the new default repo
	redirect =<< liftIO geturl
  where
	geturl = do
		r <- Git.Config.read =<< Git.Construct.fromPath repo
		waiturl $ gitAnnexUrlFile r
	waiturl urlfile = do
		v <- tryIO $ readFile urlfile
		case v of
			Left _ -> delayed $ waiturl urlfile
			Right url -> ifM (listening url)
				( return url
				, delayed $ waiturl urlfile
				)
	listening url = catchBoolIO $ fst <$> Url.exists url []
	delayed a = do
		threadDelay 100000 -- 1/10th of a second
		a

startAssistant :: FilePath -> IO ()
startAssistant repo = do
	program <- readProgramFile
	void $ forkIO $ void $ createProcess $
		(proc program ["assistant"]) { cwd = Just repo }
