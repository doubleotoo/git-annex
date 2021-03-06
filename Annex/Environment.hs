{- git-annex environment
 -
 - Copyright 2012, 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Annex.Environment where

import Common.Annex
import Utility.Env
import Utility.UserInfo
import qualified Git.Config

{- Checks that the system's environment allows git to function.
 - Git requires a GECOS username, or suitable git configuration, or
 - environment variables. -}
checkEnvironment :: Annex ()
checkEnvironment = do
	gitusername <- fromRepo $ Git.Config.getMaybe "user.name"
	when (gitusername == Nothing || gitusername == Just "") $
		liftIO checkEnvironmentIO

checkEnvironmentIO :: IO ()
checkEnvironmentIO =
#ifdef __WINDOWS__
	noop
#else
	whenM (null <$> myUserGecos) $ do
		username <- myUserName
		ensureEnv "GIT_AUTHOR_NAME" username
		ensureEnv "GIT_COMMITTER_NAME" username
  where
#ifndef __ANDROID__
  	-- existing environment is not overwritten
	ensureEnv var val = void $ setEnv var val False
#else
	-- Environment setting is broken on Android, so this is dealt with
	-- in runshell instead.
	ensureEnv _ _ = noop
#endif
#endif
