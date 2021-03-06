{- git-annex assistant dropping of unwanted content
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Assistant.Drop where

import Assistant.Common
import Assistant.DaemonStatus
import Logs.Location
import Logs.Trust
import Types.Remote (AssociatedFile, uuid)
import qualified Remote
import qualified Command.Drop
import Command
import Annex.Wanted
import Annex.Exception
import Config
import Annex.Content.Direct

import qualified Data.Set as S

type Reason = String

{- Drop from local and/or remote when allowed by the preferred content and
 - numcopies settings. -}
handleDrops :: Reason -> Bool -> Key -> AssociatedFile -> Maybe Remote -> Assistant ()
handleDrops _ _ _ Nothing _ = noop
handleDrops reason fromhere key f knownpresentremote = do
	syncrs <- syncDataRemotes <$> getDaemonStatus
	locs <- liftAnnex $ loggedLocations key
	handleDropsFrom locs syncrs reason fromhere key f knownpresentremote

{- The UUIDs are ones where the content is believed to be present.
 - The Remote list can include other remotes that do not have the content;
 - only ones that match the UUIDs will be dropped from.
 - If allowed to drop fromhere, that drop will be tried first.
 -
 - In direct mode, all associated files are checked, and only if all
 - of them are unwanted are they dropped.
 -}
handleDropsFrom :: [UUID] -> [Remote] -> Reason -> Bool -> Key -> AssociatedFile -> Maybe Remote -> Assistant ()
handleDropsFrom _ _ _ _ _ Nothing _ = noop
handleDropsFrom locs rs reason fromhere key (Just afile) knownpresentremote = do
	fs <- liftAnnex $ ifM isDirect
		( associatedFilesRelative key
		, return [afile]
		)
	n <- getcopies fs
	if fromhere && checkcopies n Nothing
		then go fs rs =<< dropl fs n
		else go fs rs n
  where
	getcopies fs = liftAnnex $ do
		(untrusted, have) <- trustPartition UnTrusted locs
		numcopies <- maximum <$> mapM (getNumCopies <=< numCopies) fs
		return (length have, numcopies, S.fromList untrusted)

	{- Check that we have enough copies still to drop the content.
	 - When the remote being dropped from is untrusted, it was not
	 - counted as a copy, so having only numcopies suffices. Otherwise,
	 - we need more than numcopies to safely drop. -}
	checkcopies (have, numcopies, _untrusted) Nothing = have > numcopies
	checkcopies (have, numcopies, untrusted) (Just u)
		| S.member u untrusted = have >= numcopies
		| otherwise = have > numcopies
	
	decrcopies (have, numcopies, untrusted) Nothing =
		(have - 1, numcopies, untrusted)
	decrcopies v@(_have, _numcopies, untrusted) (Just u)
		| S.member u untrusted = v
		| otherwise = decrcopies v Nothing

	go _ [] _ = noop
	go fs (r:rest) n
		| uuid r `S.notMember` slocs = go fs rest n
		| checkcopies n (Just $ Remote.uuid r) =
			dropr fs r n >>= go fs rest
		| otherwise = noop

	checkdrop fs n@(have, numcopies, _untrusted) u a =
		ifM (liftAnnex $ allM (wantDrop True u . Just) fs)
			( ifM (liftAnnex $ safely $ doCommand $ a (Just numcopies))
				( do
					debug
						[ "dropped"
						, afile
						, "(from " ++ maybe "here" show u ++ ")"
						, "(copies now " ++ show (have - 1) ++ ")"
						, ": " ++ reason
						]
					return $ decrcopies n u
				, return n
				)
			, return n
			)

	dropl fs n = checkdrop fs n Nothing $ \numcopies ->
		Command.Drop.startLocal afile numcopies key knownpresentremote

	dropr fs r n  = checkdrop fs n (Just $ Remote.uuid r) $ \numcopies ->
		Command.Drop.startRemote afile numcopies key r

	safely a = either (const False) id <$> tryAnnex a

	slocs = S.fromList locs
