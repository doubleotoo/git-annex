{- git-annex command
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Log where

import qualified Data.Set as S
import qualified Data.ByteString.Lazy.Char8 as L
import Data.Time.Clock.POSIX
import Data.Time
import System.Locale
import Data.Char

import Common.Annex
import Command
import qualified Logs.Location
import qualified Logs.Presence
import Annex.CatFile
import qualified Annex.Branch
import qualified Git
import Git.Command
import qualified Remote
import qualified Option
import qualified Annex

data RefChange = RefChange 
	{ changetime :: POSIXTime
	, oldref :: Git.Ref
	, newref :: Git.Ref
	}

def :: [Command]
def = [withOptions options $
	command "log" paramPaths seek "shows location log"]

options :: [Option]
options = map odate ["since", "after", "until", "before"] ++
	[ Option.field ['n'] "max-count" paramNumber
		"limit number of logs displayed"
	]
	where
		odate n = Option.field [] n paramDate $
			"show log " ++ n ++ " date"

seek :: [CommandSeek]
seek = [withValue (concat <$> mapM getoption options) $ \os ->
	withFilesInGit $ whenAnnexed $ start os]
	where
		getoption o = maybe [] (use o) <$>
			Annex.getField (Option.name o)
		use o v = [Param ("--" ++ Option.name o), Param v]

start :: [CommandParam] -> FilePath -> (Key, Backend) -> CommandStart
start os file (key, _) = do
	showLog file =<< readLog <$> getLog key os
	stop

showLog :: FilePath -> [RefChange] -> Annex ()
showLog file ps = do
	zone <- liftIO getCurrentTimeZone
	sets <- mapM (getset newref) ps
	previous <- maybe (return genesis) (getset oldref) (lastMaybe ps)
	sequence_ $ compareChanges (output zone) $ sets ++ [previous]
	where
		genesis = (0, S.empty)
		getset select change = do
			s <- S.fromList <$> get (select change)
			return (changetime change, s)
		get ref = map toUUID . Logs.Presence.getLog . L.unpack <$>
			catObject ref
		output zone present ts s = do
			rs <- map (dropWhile isSpace) . lines <$>
				Remote.prettyPrintUUIDs "log" (S.toList s)
			liftIO $ mapM_ (putStrLn . format) rs
				where
					time = showTimeStamp zone ts
					addel = if present then "+" else "-"
					format r = unwords
						[ addel, time, file, "|", r ]

{- Generates a display of the changes (which are ordered with newest first),
 - by comparing each change with the previous change.
 - Uses a formater to generate a display of items that are added and
 - removed. -}
compareChanges :: Ord a => (Bool -> POSIXTime -> S.Set a -> b) -> [(POSIXTime, S.Set a)] -> [b]
compareChanges format changes = concatMap diff $ zip changes (drop 1 changes)
	where
		diff ((ts, new), (_, old)) =
			[format True ts added, format False ts removed]
			where
				added = S.difference new old
				removed = S.difference old new

{- Gets the git log for a given location log file.
 -
 - This is complicated by git log using paths relative to the current
 - directory, even when looking at files in a different branch. A wacky
 - relative path to the log file has to be used.
 -
 - The --remove-empty is a significant optimisation. It relies on location
 - log files never being deleted in normal operation. Letting git stop
 - once the location log file is gone avoids it checking all the way back
 - to commit 0 to see if it used to exist, so generally speeds things up a
 - *lot* for newish files. -}
getLog :: Key -> [CommandParam] -> Annex [String]
getLog key os = do
	top <- fromRepo Git.workTree
	p <- liftIO $ relPathCwdToFile top
	let logfile = p </> Logs.Location.logFile key
	inRepo $ pipeNullSplit $
		[ Params "log -z --pretty=format:%ct --raw --abbrev=40"
		, Param "--remove-empty"
		] ++ os ++
		[ Param $ show Annex.Branch.fullname
		, Param "--"
		, Param logfile
		]

readLog :: [String] -> [RefChange]
readLog = mapMaybe (parse . lines)
	where
		parse (ts:raw:[]) = let (old, new) = parseRaw raw in
			Just RefChange
				{ changetime = parseTimeStamp ts
				, oldref = old
				, newref = new
				}
		parse _ = Nothing

-- Parses something like ":100644 100644 oldsha newsha M"
parseRaw :: String -> (Git.Ref, Git.Ref)
parseRaw l = (Git.Ref oldsha, Git.Ref newsha)
	where
		ws = words l
		oldsha = ws !! 2
		newsha = ws !! 3

parseTimeStamp :: String -> POSIXTime
parseTimeStamp = utcTimeToPOSIXSeconds . fromMaybe (error "bad timestamp") .
	parseTime defaultTimeLocale "%s"

showTimeStamp :: TimeZone -> POSIXTime -> String
showTimeStamp zone = show . utcToLocalTime zone . posixSecondsToUTCTime
