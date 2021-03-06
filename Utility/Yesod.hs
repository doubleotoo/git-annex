{- Yesod stuff, that's typically found in the scaffolded site.
 -
 - Also a bit of a compatability layer to make it easier to support yesod
 - 1.1 and 1.2 in the same code base.
 -
 - Copyright 2012, 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP, RankNTypes, FlexibleContexts #-}

module Utility.Yesod where

import Yesod
#if MIN_VERSION_yesod_default(1,2,0)
import Yesod.Core
#endif
#ifndef __ANDROID__
import Yesod.Default.Util
import Language.Haskell.TH.Syntax (Q, Exp)
#if MIN_VERSION_yesod_default(1,1,0)
import Data.Default (def)
import Text.Hamlet
#endif

widgetFile :: String -> Q Exp
#if ! MIN_VERSION_yesod_default(1,1,0)
widgetFile = widgetFileNoReload
#else
widgetFile = widgetFileNoReload $ def
	{ wfsHamletSettings = defaultHamletSettings
		{ hamletNewlines = AlwaysNewlines
		}
	}
#endif

hamletTemplate :: FilePath -> FilePath
hamletTemplate f = globFile "hamlet" f
#endif

{- Lift Handler to Widget -}
#if MIN_VERSION_yesod(1,2,0)
liftH :: Monad m => HandlerT site m a -> WidgetT site m a
liftH = liftH
#else
liftH :: MonadLift base m => base a -> m a
liftH = lift
#endif
