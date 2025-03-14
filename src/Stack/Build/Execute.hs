{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TypeFamilies          #-}

-- | Perform a build
module Stack.Build.Execute
  ( printPlan
  , preFetch
  , executePlan
  -- * Running Setup.hs
  , ExecuteEnv
  , withExecuteEnv
  , withSingleContext
  , ExcludeTHLoading (..)
  , KeepOutputOpen (..)
  ) where

import           Control.Concurrent.Companion ( Companion, withCompanion )
import           Control.Concurrent.Execute
                   ( Action (..), ActionContext (..), ActionId (..)
                   , ActionType (..)
                   , Concurrency (..), runActions
                   )
import           Control.Concurrent.STM ( check )
import           Crypto.Hash ( SHA256 (..), hashWith )
import           Data.Attoparsec.Text ( char, choice, digit, parseOnly )
import qualified Data.Attoparsec.Text as P ( string )
import qualified Data.ByteArray as Mem ( convert )
import qualified Data.ByteString as S
import qualified Data.ByteString.Builder ( toLazyByteString )
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Base64.URL as B64URL
import           Data.Char ( isSpace )
import           Conduit
                   ( ConduitT, awaitForever, runConduitRes, sinkHandle
                   , withSinkFile, withSourceFile, yield
                   )
import qualified Data.Conduit.Binary as CB
import qualified Data.Conduit.Filesystem as CF
import qualified Data.Conduit.List as CL
import           Data.Conduit.Process.Typed ( createSource )
import qualified Data.Conduit.Text as CT
import qualified Data.List as L
import           Data.List.Split ( chunksOf )
import qualified Data.Map.Merge.Strict as Map
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import           Data.Text.Encoding ( decodeUtf8 )
import           Data.Tuple ( swap )
import           Data.Time
                   ( ZonedTime, getZonedTime, formatTime, defaultTimeLocale )
import qualified Data.ByteString.Char8 as S8
import qualified Distribution.PackageDescription as C
import qualified Distribution.Simple.Build.Macros as C
import           Distribution.System ( OS (Windows), Platform (Platform) )
import qualified Distribution.Text as C
import           Distribution.Types.MungedPackageName
                   ( encodeCompatPackageName )
import           Distribution.Types.PackageName ( mkPackageName )
import           Distribution.Types.UnqualComponentName
                   ( mkUnqualComponentName )
import           Distribution.Verbosity ( showForCabal )
import           Distribution.Version ( mkVersion )
import           GHC.Records ( getField )
import           Path
                   ( PathException, (</>), addExtension, filename
                   , isProperPrefixOf, parent, parseRelDir, parseRelFile
                   , stripProperPrefix
                   )
import           Path.CheckInstall ( warnInstallSearchPathIssues )
import           Path.Extra
                   ( forgivingResolveFile, rejectMissingFile
                   , toFilePathNoTrailingSep
                   )
import           Path.IO
                   ( copyFile, doesDirExist, doesFileExist, ensureDir
                   , ignoringAbsence, removeDirRecur, removeFile, renameDir
                   , renameFile
                   )
import           RIO.NonEmpty ( nonEmpty )
import qualified RIO.NonEmpty as NE
import           RIO.Process
                   ( HasProcessContext, byteStringInput, eceExitCode
                   , findExecutable, getStderr, getStdout, inherit
                   , modifyEnvVars, proc, runProcess_, setStderr, setStdin
                   , setStdout, showProcessArgDebug, useHandleOpen, waitExitCode
                   , withProcessWait, withWorkingDir
                   )
import           Stack.Build.Cache
                   ( TestStatus (..), deleteCaches, getTestStatus
                   , markExeInstalled, markExeNotInstalled, readPrecompiledCache
                   , setTestStatus, tryGetCabalMod, tryGetConfigCache
                   , tryGetPackageProjectRoot, tryGetSetupConfigMod
                   , writeBuildCache, writeCabalMod, writeConfigCache
                   , writeFlagCache, writePrecompiledCache
                   , writePackageProjectRoot, writeSetupConfigMod
                   )
import           Stack.Build.Haddock
                   ( generateDepsHaddockIndex
                   , generateLocalHaddockForHackageArchives
                   , generateLocalHaddockIndex, generateSnapHaddockIndex
                   , openHaddocksInBrowser
                   )
import           Stack.Build.Installed (  )
import           Stack.Build.Source ( addUnlistedToBuildCache )
import           Stack.Build.Target (  )
import           Stack.Config ( checkOwnership )
import           Stack.Config.ConfigureScript ( ensureConfigureScript )
import           Stack.Constants
                   ( bindirSuffix, cabalPackageName, compilerOptionsCabalFlag
                   , relDirBuild, relDirDist, relDirSetup, relDirSetupExeCache
                   , relDirSetupExeSrc, relFileBuildLock, relFileSetupHs
                   , relFileSetupLhs, relFileSetupLower, relFileSetupMacrosH
                   , setupGhciShimCode, stackProgName, testGhcEnvRelFile
                   )
import           Stack.Constants.Config
                   ( distDirFromDir, distRelativeDir, hpcDirFromDir
                   , hpcRelativeDir, setupConfigFromDir
                   )
import           Stack.Coverage
                   ( deleteHpcReports, generateHpcMarkupIndex, generateHpcReport
                   , generateHpcUnifiedReport, updateTixFile
                   )
import           Stack.GhcPkg ( ghcPkg, unregisterGhcPkgIds )
import           Stack.Package
                   ( buildLogPath, buildableExes, buildableSubLibs
                   , hasBuildableMainLibrary, mainLibraryHasExposedModules
                   )
import           Stack.PackageDump ( conduitDumpPackage, ghcPkgDescribe )
import           Stack.Prelude
import           Stack.Types.ApplyGhcOptions ( ApplyGhcOptions (..) )
import           Stack.Types.Build
                   ( ConfigCache (..), Plan (..), PrecompiledCache (..)
                   , Task (..), TaskConfigOpts (..), TaskType (..)
                   , configCacheComponents, taskAnyMissing, taskIsTarget
                   , taskLocation, taskProvides, taskTypeLocation
                   , taskTypePackageIdentifier
                   )
import           Stack.Types.Build.Exception
                   ( BuildException (..), BuildPrettyException (..) )
import           Stack.Types.BuildConfig
                   ( BuildConfig (..), HasBuildConfig (..), projectRootL )
import           Stack.Types.BuildOpts
                   ( BenchmarkOpts (..), BuildOpts (..), BuildOptsCLI (..)
                   , CabalVerbosity (..), HaddockOpts (..)
                   , ProgressBarFormat (..), TestOpts (..)
                   )
import           Stack.Types.CompCollection
                   ( collectionKeyValueList, collectionLookup
                   , getBuildableListAs, getBuildableListText
                   )
import           Stack.Types.Compiler
                   ( ActualCompiler (..), WhichCompiler (..)
                   , compilerVersionString, getGhcVersion, whichCompilerL
                   )
import           Stack.Types.CompilerPaths
                   ( CompilerPaths (..), GhcPkgExe (..), HasCompiler (..)
                   , cabalVersionL, cpWhich, getCompilerPath, getGhcPkgExe
                   )
import qualified Stack.Types.Component as Component
import           Stack.Types.Config
                   ( Config (..), HasConfig (..), buildOptsL, stackRootL )
import           Stack.Types.ConfigureOpts
                   ( BaseConfigOpts (..), ConfigureOpts (..) )
import           Stack.Types.Dependency (DepValue(dvVersionRange))
import           Stack.Types.DumpLogs ( DumpLogs (..) )
import           Stack.Types.DumpPackage ( DumpPackage (..) )
import           Stack.Types.EnvConfig
                   ( HasEnvConfig (..), actualCompilerVersionL
                   , appropriateGhcColorFlag, bindirCompilerTools
                   , installationRootDeps, installationRootLocal
                   , packageDatabaseLocal, platformGhcRelDir
                   , shouldForceGhcColorFlag
                   )
import           Stack.Types.EnvSettings ( EnvSettings (..) )
import           Stack.Types.GhcPkgId ( GhcPkgId, ghcPkgIdString, unGhcPkgId )
import           Stack.Types.GlobalOpts ( GlobalOpts (..) )
import           Stack.Types.Installed
                   ( InstallLocation (..), Installed (..), InstalledMap
                   , InstalledLibraryInfo (..), installedPackageIdentifier
                   )
import           Stack.Types.IsMutable ( IsMutable (..) )
import           Stack.Types.NamedComponent
                   ( NamedComponent, benchComponents, exeComponents, isCBench
                   , isCTest, renderComponent, testComponents
                   )
import           Stack.Types.Package
                   ( LocalPackage (..), Package (..), installedMapGhcPkgId
                   , packageIdentifier, runMemoizedWith, simpleInstalledLib
                   , toCabalMungedPackageName
                   )
import           Stack.Types.PackageFile ( PackageWarning (..) )
import           Stack.Types.Platform ( HasPlatform (..) )
import           Stack.Types.Curator ( Curator (..) )
import           Stack.Types.Runner ( HasRunner, globalOptsL, terminalL )
import           Stack.Types.SourceMap ( Target )
import           Stack.Types.Version ( withinRange )
import qualified System.Directory as D
import           System.Environment ( getExecutablePath, lookupEnv )
import           System.FileLock
                   ( SharedExclusive (Exclusive), withFileLock, withTryFileLock
                   )
import qualified System.FilePath as FP
import           System.IO.Error ( isDoesNotExistError )
import           System.PosixCompat.Files
                   ( createLink, getFileStatus, modificationTime )
import           System.Random ( randomIO )

-- | Has an executable been built or not?
data ExecutableBuildStatus
  = ExecutableBuilt
  | ExecutableNotBuilt
  deriving (Eq, Ord, Show)

-- | Fetch the packages necessary for a build, for example in combination with
-- a dry run.
preFetch :: HasEnvConfig env => Plan -> RIO env ()
preFetch plan
  | Set.null pkgLocs = logDebug "Nothing to fetch"
  | otherwise = do
      logDebug $
           "Prefetching: "
        <> mconcat (L.intersperse ", " (display <$> Set.toList pkgLocs))
      fetchPackages pkgLocs
 where
  pkgLocs = Set.unions $ map toPkgLoc $ Map.elems $ planTasks plan

  toPkgLoc task =
    case taskType task of
      TTLocalMutable{} -> Set.empty
      TTRemotePackage _ _ pkgloc -> Set.singleton pkgloc

-- | Print a description of build plan for human consumption.
printPlan :: (HasRunner env, HasTerm env) => Plan -> RIO env ()
printPlan plan = do
  case Map.elems $ planUnregisterLocal plan of
    [] -> prettyInfo $
               flow "No packages would be unregistered."
            <> line
    xs -> do
      let unregisterMsg (ident, reason) = fillSep $
              fromString (packageIdentifierString ident)
            : [ parens $ flow (T.unpack reason) | not $ T.null reason ]
      prettyInfo $
           flow "Would unregister locally:"
        <> line
        <> bulletedList (map unregisterMsg xs)
        <> line

  case Map.elems $ planTasks plan of
    [] -> prettyInfo $
               flow "Nothing to build."
            <> line
    xs -> do
      prettyInfo $
           flow "Would build:"
        <> line
        <> bulletedList (map displayTask xs)
        <> line

  let hasTests = not . Set.null . testComponents . taskComponents
      hasBenches = not . Set.null . benchComponents . taskComponents
      tests = Map.elems $ Map.filter hasTests $ planFinals plan
      benches = Map.elems $ Map.filter hasBenches $ planFinals plan

  unless (null tests) $ do
    prettyInfo $
         flow "Would test:"
      <> line
      <> bulletedList (map displayTask tests)
      <> line

  unless (null benches) $ do
    prettyInfo $
         flow "Would benchmark:"
      <> line
      <> bulletedList (map displayTask benches)
      <> line

  case Map.toList $ planInstallExes plan of
    [] -> prettyInfo $
               flow "No executables to be installed."
            <> line
    xs -> do
      let executableMsg (name, loc) = fillSep $
              fromString (T.unpack name)
            : "from"
            : ( case loc of
                  Snap -> "snapshot" :: StyleDoc
                  Local -> "local" :: StyleDoc
              )
            : ["database."]
      prettyInfo $
           flow "Would install executables:"
        <> line
        <> bulletedList (map executableMsg xs)
        <> line

-- | For a dry run
displayTask :: Task -> StyleDoc
displayTask task = fillSep $
     [ fromString (packageIdentifierString (taskProvides task)) <> ":"
     ,    "database="
       <> ( case taskLocation task of
              Snap -> "snapshot" :: StyleDoc
              Local -> "local" :: StyleDoc
          )
       <> ","
     ,    "source="
       <> ( case taskType task of
              TTLocalMutable lp -> pretty $ parent $ lpCabalFile lp
              TTRemotePackage _ _ pl -> fromString $ T.unpack $ textDisplay pl
          )
       <> if Set.null missing
            then mempty
            else ","
     ]
  <> [ fillSep $
           "after:"
         : mkNarrativeList Nothing False
             (map fromPackageId (Set.toList missing) :: [StyleDoc])
     | not $ Set.null missing
     ]
 where
  missing = tcoMissing $ taskConfigOpts task

data ExecuteEnv = ExecuteEnv
  { eeInstallLock    :: !(MVar ())
  , eeBuildOpts      :: !BuildOpts
  , eeBuildOptsCLI   :: !BuildOptsCLI
  , eeBaseConfigOpts :: !BaseConfigOpts
  , eeGhcPkgIds      :: !(TVar (Map PackageIdentifier Installed))
  , eeTempDir        :: !(Path Abs Dir)
  , eeSetupHs        :: !(Path Abs File)
    -- ^ Temporary Setup.hs for simple builds
  , eeSetupShimHs    :: !(Path Abs File)
    -- ^ Temporary SetupShim.hs, to provide access to initial-build-steps
  , eeSetupExe       :: !(Maybe (Path Abs File))
    -- ^ Compiled version of eeSetupHs
  , eeCabalPkgVer    :: !Version
  , eeTotalWanted    :: !Int
  , eeLocals         :: ![LocalPackage]
  , eeGlobalDB       :: !(Path Abs Dir)
  , eeGlobalDumpPkgs :: !(Map GhcPkgId DumpPackage)
  , eeSnapshotDumpPkgs :: !(TVar (Map GhcPkgId DumpPackage))
  , eeLocalDumpPkgs  :: !(TVar (Map GhcPkgId DumpPackage))
  , eeLogFiles       :: !(TChan (Path Abs Dir, Path Abs File))
  , eeCustomBuilt    :: !(IORef (Set PackageName))
    -- ^ Stores which packages with custom-setup have already had their
    -- Setup.hs built.
  , eeLargestPackageName :: !(Maybe Int)
    -- ^ For nicer interleaved output: track the largest package name size
  , eePathEnvVar :: !Text
    -- ^ Value of the PATH environment variable
  }

buildSetupArgs :: [String]
buildSetupArgs =
  [ "-rtsopts"
  , "-threaded"
  , "-clear-package-db"
  , "-global-package-db"
  , "-hide-all-packages"
  , "-package"
  , "base"
  , "-main-is"
  , "StackSetupShim.mainOverride"
  ]

simpleSetupCode :: Builder
simpleSetupCode = "import Distribution.Simple\nmain = defaultMain"

simpleSetupHash :: String
simpleSetupHash =
    T.unpack
  $ decodeUtf8
  $ S.take 8
  $ B64URL.encode
  $ Mem.convert
  $ hashWith SHA256
  $ toStrictBytes
  $ Data.ByteString.Builder.toLazyByteString
  $  encodeUtf8Builder (T.pack (unwords buildSetupArgs))
  <> setupGhciShimCode
  <> simpleSetupCode

-- | Get a compiled Setup exe
getSetupExe :: HasEnvConfig env
            => Path Abs File -- ^ Setup.hs input file
            -> Path Abs File -- ^ SetupShim.hs input file
            -> Path Abs Dir -- ^ temporary directory
            -> RIO env (Maybe (Path Abs File))
getSetupExe setupHs setupShimHs tmpdir = do
  wc <- view $ actualCompilerVersionL.whichCompilerL
  platformDir <- platformGhcRelDir
  config <- view configL
  cabalVersionString <- view $ cabalVersionL.to versionString
  actualCompilerVersionString <-
    view $ actualCompilerVersionL.to compilerVersionString
  platform <- view platformL
  let baseNameS = concat
        [ "Cabal-simple_"
        , simpleSetupHash
        , "_"
        , cabalVersionString
        , "_"
        , actualCompilerVersionString
        ]
      exeNameS = baseNameS ++
        case platform of
          Platform _ Windows -> ".exe"
          _ -> ""
      outputNameS =
        case wc of
            Ghc -> exeNameS
      setupDir =
        view stackRootL config </>
        relDirSetupExeCache </>
        platformDir

  exePath <- (setupDir </>) <$> parseRelFile exeNameS

  exists <- liftIO $ D.doesFileExist $ toFilePath exePath

  if exists
    then pure $ Just exePath
    else do
      tmpExePath <- fmap (setupDir </>) $ parseRelFile $ "tmp-" ++ exeNameS
      tmpOutputPath <-
        fmap (setupDir </>) $ parseRelFile $ "tmp-" ++ outputNameS
      ensureDir setupDir
      let args = buildSetupArgs ++
            [ "-package"
            , "Cabal-" ++ cabalVersionString
            , toFilePath setupHs
            , toFilePath setupShimHs
            , "-o"
            , toFilePath tmpOutputPath
              -- See https://github.com/commercialhaskell/stack/issues/6267. As
              -- corrupt *.hi and/or *.o files can be problematic, we aim to
              -- to leave none behind. This can be dropped when Stack drops
              -- support for the problematic versions of GHC.
            , "-no-keep-hi-files"
            , "-no-keep-o-files"
            ]
      compilerPath <- getCompilerPath
      withWorkingDir (toFilePath tmpdir) $
        proc (toFilePath compilerPath) args (\pc0 -> do
          let pc = setStdout (useHandleOpen stderr) pc0
          runProcess_ pc)
            `catch` \ece ->
              prettyThrowM $ SetupHsBuildFailure
                (eceExitCode ece) Nothing compilerPath args Nothing []
      renameFile tmpExePath exePath
      pure $ Just exePath

-- | Execute a function that takes an 'ExecuteEnv'.
withExecuteEnv ::
     forall env a. HasEnvConfig env
  => BuildOpts
  -> BuildOptsCLI
  -> BaseConfigOpts
  -> [LocalPackage]
  -> [DumpPackage] -- ^ global packages
  -> [DumpPackage] -- ^ snapshot packages
  -> [DumpPackage] -- ^ local packages
  -> Maybe Int -- ^ largest package name, for nicer interleaved output
  -> (ExecuteEnv -> RIO env a)
  -> RIO env a
withExecuteEnv bopts boptsCli baseConfigOpts locals globalPackages snapshotPackages localPackages mlargestPackageName inner =
  createTempDirFunction stackProgName $ \tmpdir -> do
    installLock <- liftIO $ newMVar ()
    idMap <- liftIO $ newTVarIO Map.empty
    config <- view configL

    customBuiltRef <- newIORef Set.empty

    -- Create files for simple setup and setup shim, if necessary
    let setupSrcDir =
            view stackRootL config </>
            relDirSetupExeSrc
    ensureDir setupSrcDir
    let setupStub = "setup-" ++ simpleSetupHash
    setupFileName <- parseRelFile (setupStub ++ ".hs")
    setupHiName <- parseRelFile (setupStub ++ ".hi")
    setupOName <- parseRelFile (setupStub ++ ".o")
    let setupHs = setupSrcDir </> setupFileName
        setupHi = setupSrcDir </> setupHiName
        setupO =  setupSrcDir </> setupOName
    setupHsExists <- doesFileExist setupHs
    unless setupHsExists $ writeBinaryFileAtomic setupHs simpleSetupCode
    -- See https://github.com/commercialhaskell/stack/issues/6267. Remove any
    -- historical *.hi or *.o files. This can be dropped when Stack drops
    -- support for the problematic versions of GHC.
    ignoringAbsence (removeFile setupHi)
    ignoringAbsence (removeFile setupO)
    let setupShimStub = "setup-shim-" ++ simpleSetupHash
    setupShimFileName <- parseRelFile (setupShimStub ++ ".hs")
    setupShimHiName <- parseRelFile (setupShimStub ++ ".hi")
    setupShimOName <- parseRelFile (setupShimStub ++ ".o")
    let setupShimHs = setupSrcDir </> setupShimFileName
        setupShimHi = setupSrcDir </> setupShimHiName
        setupShimO = setupSrcDir </> setupShimOName
    setupShimHsExists <- doesFileExist setupShimHs
    unless setupShimHsExists $
      writeBinaryFileAtomic setupShimHs setupGhciShimCode
    -- See https://github.com/commercialhaskell/stack/issues/6267. Remove any
    -- historical *.hi or *.o files. This can be dropped when Stack drops
    -- support for the problematic versions of GHC.
    ignoringAbsence (removeFile setupShimHi)
    ignoringAbsence (removeFile setupShimO)
    setupExe <- getSetupExe setupHs setupShimHs tmpdir

    cabalPkgVer <- view cabalVersionL
    globalDB <- view $ compilerPathsL.to cpGlobalDB
    snapshotPackagesTVar <-
      liftIO $ newTVarIO (toDumpPackagesByGhcPkgId snapshotPackages)
    localPackagesTVar <-
      liftIO $ newTVarIO (toDumpPackagesByGhcPkgId localPackages)
    logFilesTChan <- liftIO $ atomically newTChan
    let totalWanted = length $ filter lpWanted locals
    pathEnvVar <- liftIO $ maybe mempty T.pack <$> lookupEnv "PATH"
    inner ExecuteEnv
      { eeBuildOpts = bopts
      , eeBuildOptsCLI = boptsCli
        -- Uncertain as to why we cannot run configures in parallel. This
        -- appears to be a Cabal library bug. Original issue:
        -- https://github.com/commercialhaskell/stack/issues/84. Ideally
        -- we'd be able to remove this.
      , eeInstallLock = installLock
      , eeBaseConfigOpts = baseConfigOpts
      , eeGhcPkgIds = idMap
      , eeTempDir = tmpdir
      , eeSetupHs = setupHs
      , eeSetupShimHs = setupShimHs
      , eeSetupExe = setupExe
      , eeCabalPkgVer = cabalPkgVer
      , eeTotalWanted = totalWanted
      , eeLocals = locals
      , eeGlobalDB = globalDB
      , eeGlobalDumpPkgs = toDumpPackagesByGhcPkgId globalPackages
      , eeSnapshotDumpPkgs = snapshotPackagesTVar
      , eeLocalDumpPkgs = localPackagesTVar
      , eeLogFiles = logFilesTChan
      , eeCustomBuilt = customBuiltRef
      , eeLargestPackageName = mlargestPackageName
      , eePathEnvVar = pathEnvVar
      } `finally` dumpLogs logFilesTChan totalWanted
 where
  toDumpPackagesByGhcPkgId = Map.fromList . map (\dp -> (dpGhcPkgId dp, dp))

  createTempDirFunction
    | boptsKeepTmpFiles bopts = withKeepSystemTempDir
    | otherwise = withSystemTempDir

  dumpLogs :: TChan (Path Abs Dir, Path Abs File) -> Int -> RIO env ()
  dumpLogs chan totalWanted = do
    allLogs <- fmap reverse $ liftIO $ atomically drainChan
    case allLogs of
      -- No log files generated, nothing to dump
      [] -> pure ()
      firstLog:_ -> do
        toDump <- view $ configL.to configDumpLogs
        case toDump of
          DumpAllLogs -> mapM_ (dumpLog "") allLogs
          DumpWarningLogs -> mapM_ dumpLogIfWarning allLogs
          DumpNoLogs
              | totalWanted > 1 ->
                  prettyInfoL
                    [ flow "Build output has been captured to log files, use"
                    , style Shell "--dump-logs"
                    , flow "to see it on the console."
                    ]
              | otherwise -> pure ()
        prettyInfoL
          [ flow "Log files have been written to:"
          , pretty (parent (snd firstLog))
          ]

    -- We only strip the colors /after/ we've dumped logs, so that we get pretty
    -- colors in our dump output on the terminal.
    colors <- shouldForceGhcColorFlag
    when colors $ liftIO $ mapM_ (stripColors . snd) allLogs
   where
    drainChan :: STM [(Path Abs Dir, Path Abs File)]
    drainChan = do
      mx <- tryReadTChan chan
      case mx of
        Nothing -> pure []
        Just x -> do
          xs <- drainChan
          pure $ x:xs

  dumpLogIfWarning :: (Path Abs Dir, Path Abs File) -> RIO env ()
  dumpLogIfWarning (pkgDir, filepath) = do
    firstWarning <- withSourceFile (toFilePath filepath) $ \src ->
         runConduit
       $ src
      .| CT.decodeUtf8Lenient
      .| CT.lines
      .| CL.map stripCR
      .| CL.filter isWarning
      .| CL.take 1
    unless (null firstWarning) $ dumpLog " due to warnings" (pkgDir, filepath)

  isWarning :: Text -> Bool
  isWarning t = ": Warning:" `T.isSuffixOf` t -- prior to GHC 8
             || ": warning:" `T.isInfixOf` t -- GHC 8 is slightly different
             || "mwarning:" `T.isInfixOf` t -- colorized output

  dumpLog :: String -> (Path Abs Dir, Path Abs File) -> RIO env ()
  dumpLog msgSuffix (pkgDir, filepath) = do
    prettyNote $
         fillSep
           ( ( fillSep
                 ( flow "Dumping log file"
                 : [ flow msgSuffix | not (L.null msgSuffix) ]
                 )
             <> ":"
             )
           : [ pretty filepath <> "." ]
           )
      <> line
    compilerVer <- view actualCompilerVersionL
    withSourceFile (toFilePath filepath) $ \src ->
         runConduit
       $ src
      .| CT.decodeUtf8Lenient
      .| mungeBuildOutput ExcludeTHLoading ConvertPathsToAbsolute pkgDir compilerVer
      .| CL.mapM_ (logInfo . display)
    prettyNote $
         fillSep
           [ flow "End of log file:"
           , pretty filepath <> "."
           ]
      <> line

  stripColors :: Path Abs File -> IO ()
  stripColors fp = do
    let colorfp = toFilePath fp ++ "-color"
    withSourceFile (toFilePath fp) $ \src ->
      withSinkFile colorfp $ \sink ->
      runConduit $ src .| sink
    withSourceFile colorfp $ \src ->
      withSinkFile (toFilePath fp) $ \sink ->
      runConduit $ src .| noColors .| sink

   where
    noColors = do
      CB.takeWhile (/= 27) -- ESC
      mnext <- CB.head
      case mnext of
        Nothing -> pure ()
        Just x -> assert (x == 27) $ do
          -- Color sequences always end with an m
          CB.dropWhile (/= 109) -- m
          CB.drop 1 -- drop the m itself
          noColors

-- | Perform the actual plan
executePlan :: HasEnvConfig env
            => BuildOptsCLI
            -> BaseConfigOpts
            -> [LocalPackage]
            -> [DumpPackage] -- ^ global packages
            -> [DumpPackage] -- ^ snapshot packages
            -> [DumpPackage] -- ^ local packages
            -> InstalledMap
            -> Map PackageName Target
            -> Plan
            -> RIO env ()
executePlan
    boptsCli
    baseConfigOpts
    locals
    globalPackages
    snapshotPackages
    localPackages
    installedMap
    targets
    plan
  = do
    logDebug "Executing the build plan"
    bopts <- view buildOptsL
    withExecuteEnv
      bopts
      boptsCli
      baseConfigOpts
      locals
      globalPackages
      snapshotPackages
      localPackages
      mlargestPackageName
      (executePlan' installedMap targets plan)

    copyExecutables (planInstallExes plan)

    config <- view configL
    menv' <- liftIO $ configProcessContextSettings config EnvSettings
               { esIncludeLocals = True
               , esIncludeGhcPackagePath = True
               , esStackExe = True
               , esLocaleUtf8 = False
               , esKeepGhcRts = False
               }
    withProcessContext menv' $
      forM_ (boptsCLIExec boptsCli) $ \(cmd, args) ->
      proc cmd args runProcess_
 where
  mlargestPackageName =
    Set.lookupMax $
    Set.map (length . packageNameString) $
    Map.keysSet (planTasks plan) <> Map.keysSet (planFinals plan)

copyExecutables ::
       HasEnvConfig env
    => Map Text InstallLocation
    -> RIO env ()
copyExecutables exes | Map.null exes = pure ()
copyExecutables exes = do
  snapBin <- (</> bindirSuffix) <$> installationRootDeps
  localBin <- (</> bindirSuffix) <$> installationRootLocal
  compilerSpecific <- boptsInstallCompilerTool <$> view buildOptsL
  destDir <- if compilerSpecific
               then bindirCompilerTools
               else view $ configL.to configLocalBin
  ensureDir destDir

  destDir' <- liftIO . D.canonicalizePath . toFilePath $ destDir

  platform <- view platformL
  let ext =
        case platform of
          Platform _ Windows -> ".exe"
          _ -> ""

  currExe <- liftIO getExecutablePath -- needed for windows, see below

  installed <- forMaybeM (Map.toList exes) $ \(name, loc) -> do
    let bindir =
            case loc of
                Snap -> snapBin
                Local -> localBin
    mfp <- forgivingResolveFile bindir (T.unpack name ++ ext)
      >>= rejectMissingFile
    case mfp of
      Nothing -> do
        prettyWarnL
          [ flow "Couldn't find executable"
          , style Current (fromString $ T.unpack name)
          , flow "in directory"
          , pretty bindir <> "."
          ]
        pure Nothing
      Just file -> do
        let destFile = destDir' FP.</> T.unpack name ++ ext
        prettyInfoL
          [ flow "Copying from"
          , pretty file
          , "to"
          , style File (fromString destFile) <> "."
          ]

        liftIO $ case platform of
          Platform _ Windows | FP.equalFilePath destFile currExe ->
              windowsRenameCopy (toFilePath file) destFile
          _ -> D.copyFile (toFilePath file) destFile
        pure $ Just (name <> T.pack ext)

  unless (null installed) $ do
    prettyInfo $
         fillSep
           [ flow "Copied executables to"
           , pretty destDir <> ":"
           ]
      <> line
      <> bulletedList
           (map (fromString . T.unpack . textDisplay) installed :: [StyleDoc])
  unless compilerSpecific $ warnInstallSearchPathIssues destDir' installed


-- | Windows can't write over the current executable. Instead, we rename the
-- current executable to something else and then do the copy.
windowsRenameCopy :: FilePath -> FilePath -> IO ()
windowsRenameCopy src dest = do
  D.copyFile src new
  D.renameFile dest old
  D.renameFile new dest
 where
  new = dest ++ ".new"
  old = dest ++ ".old"

-- | Perform the actual plan (internal)
executePlan' :: HasEnvConfig env
             => InstalledMap
             -> Map PackageName Target
             -> Plan
             -> ExecuteEnv
             -> RIO env ()
executePlan' installedMap0 targets plan ee@ExecuteEnv {..} = do
  when (toCoverage $ boptsTestOpts eeBuildOpts) deleteHpcReports
  cv <- view actualCompilerVersionL
  case nonEmpty . Map.toList $ planUnregisterLocal plan of
    Nothing -> pure ()
    Just ids -> do
      localDB <- packageDatabaseLocal
      unregisterPackages cv localDB ids

  liftIO $ atomically $ modifyTVar' eeLocalDumpPkgs $ \initMap ->
    foldl' (flip Map.delete) initMap $ Map.keys (planUnregisterLocal plan)

  run <- askRunInIO

  -- If running tests concurrently with each other, then create an MVar
  -- which is empty while each test is being run.
  concurrentTests <- view $ configL.to configConcurrentTests
  mtestLock <- if concurrentTests
                 then pure Nothing
                 else Just <$> liftIO (newMVar ())

  let actions = concatMap (toActions installedMap' mtestLock run ee) $
        Map.elems $ Map.merge
          (Map.mapMissing (\_ b -> (Just b, Nothing)))
          (Map.mapMissing (\_ f -> (Nothing, Just f)))
          (Map.zipWithMatched (\_ b f -> (Just b, Just f)))
          (planTasks plan)
          (planFinals plan)
  threads <- view $ configL.to configJobs
  let keepGoing =
        fromMaybe (not (Map.null (planFinals plan))) (boptsKeepGoing eeBuildOpts)
  terminal <- view terminalL
  terminalWidth <- view termWidthL
  errs <- liftIO $ runActions threads keepGoing actions $
    \doneVar actionsVar -> do
      let total = length actions
          loop prev
            | prev == total =
                run $ logStickyDone
                  ( "Completed " <> display total <> " action(s).")
            | otherwise = do
                inProgress <- readTVarIO actionsVar
                let packageNames = map
                      (\(ActionId pkgID _) -> pkgName pkgID)
                      (toList inProgress)
                    nowBuilding :: [PackageName] -> Utf8Builder
                    nowBuilding []    = ""
                    nowBuilding names = mconcat $
                        ": "
                      : L.intersperse ", " (map fromPackageName names)
                    progressFormat = boptsProgressBar eeBuildOpts
                    progressLine prev' total' =
                         "Progress "
                      <> display prev' <> "/" <> display total'
                      <> if progressFormat == CountOnlyBar
                           then mempty
                           else nowBuilding packageNames
                    ellipsize n text =
                      if T.length text <= n || progressFormat /= CappedBar
                        then text
                        else T.take (n - 1) text <> "…"
                when (terminal && progressFormat /= NoBar) $
                  run $ logSticky $ display $ ellipsize terminalWidth $
                    utf8BuilderToText $ progressLine prev total
                done <- atomically $ do
                  done <- readTVar doneVar
                  check $ done /= prev
                  pure done
                loop done
      when (total > 1) $ loop 0
  when (toCoverage $ boptsTestOpts eeBuildOpts) $ do
    generateHpcUnifiedReport
    generateHpcMarkupIndex
  unless (null errs) $
    prettyThrowM $ ExecutionFailure errs
  when (boptsHaddock eeBuildOpts) $ do
    if boptsHaddockForHackage eeBuildOpts
      then
        generateLocalHaddockForHackageArchives eeLocals
      else do
        snapshotDumpPkgs <- liftIO (readTVarIO eeSnapshotDumpPkgs)
        localDumpPkgs <- liftIO (readTVarIO eeLocalDumpPkgs)
        generateLocalHaddockIndex eeBaseConfigOpts localDumpPkgs eeLocals
        generateDepsHaddockIndex
          eeBaseConfigOpts
          eeGlobalDumpPkgs
          snapshotDumpPkgs
          localDumpPkgs
          eeLocals
        generateSnapHaddockIndex eeBaseConfigOpts eeGlobalDumpPkgs snapshotDumpPkgs
        when (boptsOpenHaddocks eeBuildOpts) $ do
          let planPkgs, localPkgs, installedPkgs, availablePkgs
                :: Map PackageName (PackageIdentifier, InstallLocation)
              planPkgs = Map.map (taskProvides &&& taskLocation) (planTasks plan)
              localPkgs =
                Map.fromList
                  [ (packageName p, (packageIdentifier p, Local))
                  | p <- map lpPackage eeLocals
                  ]
              installedPkgs =
                Map.map (swap . second installedPackageIdentifier) installedMap'
              availablePkgs = Map.unions [planPkgs, localPkgs, installedPkgs]
          openHaddocksInBrowser eeBaseConfigOpts availablePkgs (Map.keysSet targets)
 where
  installedMap' = Map.difference installedMap0
                $ Map.fromList
                $ map (\(ident, _) -> (pkgName ident, ()))
                $ Map.elems
                $ planUnregisterLocal plan

unregisterPackages ::
     (HasCompiler env, HasPlatform env, HasProcessContext env, HasTerm env)
  => ActualCompiler
  -> Path Abs Dir
  -> NonEmpty (GhcPkgId, (PackageIdentifier, Text))
  -> RIO env ()
unregisterPackages cv localDB ids = do
  let logReason ident reason =
        prettyInfoL
          (  [ fromString (packageIdentifierString ident) <> ":"
             , "unregistering"
             ]
          <> [ parens (flow $ T.unpack reason) | not $ T.null reason ]
          )
  let unregisterSinglePkg select (gid, (ident, reason)) = do
        logReason ident reason
        pkg <- getGhcPkgExe
        unregisterGhcPkgIds True pkg localDB $ select ident gid :| []
  case cv of
    -- GHC versions >= 8.2.1 support batch unregistering of packages. See
    -- https://gitlab.haskell.org/ghc/ghc/issues/12637
    ACGhc v | v >= mkVersion [8, 2, 1] -> do
      platform <- view platformL
      -- According to
      -- https://support.microsoft.com/en-us/help/830473/command-prompt-cmd-exe-command-line-string-limitation
      -- the maximum command line length on Windows since XP is 8191 characters.
      -- We use conservative batch size of 100 ids on this OS thus argument name
      -- '-ipid', package name, its version and a hash should fit well into this
      -- limit. On Unix-like systems we're limited by ARG_MAX which is normally
      -- hundreds of kilobytes so batch size of 500 should work fine.
      let batchSize = case platform of
            Platform _ Windows -> 100
            _ -> 500
      let chunksOfNE size = mapMaybe nonEmpty . chunksOf size . NE.toList
      for_ (chunksOfNE batchSize ids) $ \batch -> do
        for_ batch $ \(_, (ident, reason)) -> logReason ident reason
        pkg <- getGhcPkgExe
        unregisterGhcPkgIds True pkg localDB $ fmap (Right . fst) batch

    -- GHC versions >= 7.9 support unregistering of packages via their GhcPkgId.
    ACGhc v | v >= mkVersion [7, 9] ->
      for_ ids . unregisterSinglePkg $ \_ident gid -> Right gid

    _ -> for_ ids . unregisterSinglePkg $ \ident _gid -> Left ident

toActions :: HasEnvConfig env
          => InstalledMap
          -> Maybe (MVar ())
          -> (RIO env () -> IO ())
          -> ExecuteEnv
          -> (Maybe Task, Maybe Task) -- build and final
          -> [Action]
toActions installedMap mtestLock runInBase ee (mbuild, mfinal) =
  abuild ++ afinal
 where
  abuild = case mbuild of
    Nothing -> []
    Just task@Task {..} ->
      [ Action
          { actionId = ActionId (taskProvides task) ATBuild
          , actionDeps =
              Set.map (`ActionId` ATBuild) (tcoMissing taskConfigOpts)
          , actionDo =
              \ac -> runInBase $ singleBuild ac ee task installedMap False
          , actionConcurrency = ConcurrencyAllowed
          }
      ]
  afinal = case mfinal of
    Nothing -> []
    Just task@Task {..} ->
      ( if taskAllInOne
          then id
          else (:) Action
            { actionId = ActionId pkgId ATBuildFinal
            , actionDeps = addBuild
                (Set.map (`ActionId` ATBuild) (tcoMissing taskConfigOpts))
            , actionDo =
                \ac -> runInBase $ singleBuild ac ee task installedMap True
            , actionConcurrency = ConcurrencyAllowed
            }
      ) $
      -- These are the "final" actions - running tests and benchmarks.
      ( if Set.null tests
          then id
          else (:) Action
            { actionId = ActionId pkgId ATRunTests
            , actionDeps = finalDeps
            , actionDo = \ac -> withLock mtestLock $ runInBase $
                singleTest topts (Set.toList tests) ac ee task installedMap
              -- Always allow tests tasks to run concurrently with other tasks,
              -- particularly build tasks. Note that 'mtestLock' can optionally
              -- make it so that only one test is run at a time.
            , actionConcurrency = ConcurrencyAllowed
            }
      ) $
      ( if Set.null benches
          then id
          else (:) Action
            { actionId = ActionId pkgId ATRunBenchmarks
            , actionDeps = finalDeps
            , actionDo = \ac -> runInBase $
                singleBench
                  beopts
                  (Set.toList benches)
                  ac
                  ee
                  task
                  installedMap
              -- Never run benchmarks concurrently with any other task, see
              -- #3663
            , actionConcurrency = ConcurrencyDisallowed
            }
      )
      []
     where
      pkgId = taskProvides task
      comps = taskComponents task
      tests = testComponents comps
      benches = benchComponents comps
      finalDeps =
        if taskAllInOne
          then addBuild mempty
          else Set.singleton (ActionId pkgId ATBuildFinal)
      addBuild =
        case mbuild of
          Nothing -> id
          Just _ -> Set.insert $ ActionId pkgId ATBuild
  withLock Nothing f = f
  withLock (Just lock) f = withMVar lock $ \() -> f
  bopts = eeBuildOpts ee
  topts = boptsTestOpts bopts
  beopts = boptsBenchmarkOpts bopts

-- | Generate the ConfigCache
getConfigCache ::
     HasEnvConfig env
  => ExecuteEnv
  -> Task
  -> InstalledMap
  -> Bool
  -> Bool
  -> RIO env (Map PackageIdentifier GhcPkgId, ConfigCache)
getConfigCache ExecuteEnv {..} task@Task {..} installedMap enableTest enableBench = do
  let extra =
        -- We enable tests if the test suite dependencies are already
        -- installed, so that we avoid unnecessary recompilation based on
        -- cabal_macros.h changes when switching between 'stack build' and
        -- 'stack test'. See:
        -- https://github.com/commercialhaskell/stack/issues/805
        case taskType of
          TTLocalMutable _ ->
            -- FIXME: make this work with exact-configuration.
            -- Not sure how to plumb the info atm. See
            -- https://github.com/commercialhaskell/stack/issues/2049
            [ "--enable-tests" | enableTest] ++
            [ "--enable-benchmarks" | enableBench]
          TTRemotePackage{} -> []
  idMap <- liftIO $ readTVarIO eeGhcPkgIds
  let getMissing ident =
        case Map.lookup ident idMap of
          Nothing
              -- Expect to instead find it in installedMap if it's
              -- an initialBuildSteps target.
              | boptsCLIInitialBuildSteps eeBuildOptsCLI && taskIsTarget task,
                Just (_, installed) <- Map.lookup (pkgName ident) installedMap
                  -> pure $ installedToGhcPkgId ident installed
          Just installed -> pure $ installedToGhcPkgId ident installed
          _ -> throwM $ PackageIdMissingBug ident
      installedToGhcPkgId ident (Library ident' libInfo) =
        assert (ident == ident') (installedMapGhcPkgId ident libInfo)
      installedToGhcPkgId _ (Executable _) = mempty
      TaskConfigOpts missing mkOpts = taskConfigOpts
  missingMapList <- traverse getMissing $ toList missing
  let missing' = Map.unions missingMapList
      opts = mkOpts missing'
      allDeps = Set.fromList $ Map.elems missing' ++ Map.elems taskPresent
      cache = ConfigCache
        { configCacheOpts = opts
            { coNoDirs = coNoDirs opts ++ map T.unpack extra
            }
        , configCacheDeps = allDeps
        , configCacheComponents =
            case taskType of
              TTLocalMutable lp ->
                Set.map (encodeUtf8 . renderComponent) $ lpComponents lp
              TTRemotePackage{} -> Set.empty
        , configCacheHaddock = taskBuildHaddock
        , configCachePkgSrc = taskCachePkgSrc
        , configCachePathEnvVar = eePathEnvVar
        }
      allDepsMap = Map.union missing' taskPresent
  pure (allDepsMap, cache)

-- | Ensure that the configuration for the package matches what is given
ensureConfig :: HasEnvConfig env
             => ConfigCache -- ^ newConfigCache
             -> Path Abs Dir -- ^ package directory
             -> ExecuteEnv
             -> RIO env () -- ^ announce
             -> (ExcludeTHLoading -> [String] -> RIO env ()) -- ^ cabal
             -> Path Abs File -- ^ Cabal file
             -> Task
             -> RIO env Bool
ensureConfig newConfigCache pkgDir ExecuteEnv {..} announce cabal cabalfp task = do
  newCabalMod <-
    liftIO $ modificationTime <$> getFileStatus (toFilePath cabalfp)
  setupConfigfp <- setupConfigFromDir pkgDir
  let getNewSetupConfigMod =
        liftIO $ either (const Nothing) (Just . modificationTime) <$>
        tryJust
          (guard . isDoesNotExistError)
          (getFileStatus (toFilePath setupConfigfp))
  newSetupConfigMod <- getNewSetupConfigMod
  newProjectRoot <- S8.pack . toFilePath <$> view projectRootL
  -- See https://github.com/commercialhaskell/stack/issues/3554. This can be
  -- dropped when Stack drops support for GHC < 8.4.
  taskAnyMissingHackEnabled <-
    view $ actualCompilerVersionL.to getGhcVersion.to (< mkVersion [8, 4])
  needConfig <-
    if   boptsReconfigure eeBuildOpts
          -- The reason 'taskAnyMissing' is necessary is a bug in Cabal. See:
          -- <https://github.com/haskell/cabal/issues/4728#issuecomment-337937673>.
          -- The problem is that Cabal may end up generating the same package ID
          -- for a dependency, even if the ABI has changed. As a result, without
          -- check, Stack would think that a reconfigure is unnecessary, when in
          -- fact we _do_ need to reconfigure. The details here suck. We really
          -- need proper hashes for package identifiers.
       || (taskAnyMissingHackEnabled && taskAnyMissing task)
      then pure True
      else do
        -- We can ignore the components portion of the config
        -- cache, because it's just used to inform 'construct
        -- plan that we need to plan to build additional
        -- components. These components don't affect the actual
        -- package configuration.
        let ignoreComponents cc = cc { configCacheComponents = Set.empty }
        -- Determine the old and new configuration in the local directory, to
        -- determine if we need to reconfigure.
        mOldConfigCache <- tryGetConfigCache pkgDir

        mOldCabalMod <- tryGetCabalMod pkgDir

        -- Cabal's setup-config is created per OS/Cabal version, multiple
        -- projects using the same package could get a conflict because of this
        mOldSetupConfigMod <- tryGetSetupConfigMod pkgDir
        mOldProjectRoot <- tryGetPackageProjectRoot pkgDir

        pure $
                fmap ignoreComponents mOldConfigCache
             /= Just (ignoreComponents newConfigCache)
          || mOldCabalMod /= Just newCabalMod
          || mOldSetupConfigMod /= newSetupConfigMod
          || mOldProjectRoot /= Just newProjectRoot
  let ConfigureOpts dirs nodirs = configCacheOpts newConfigCache

  when (taskBuildTypeConfig task) $
    -- When build-type is Configure, we need to have a configure script in the
    -- local directory. If it doesn't exist, build it with autoreconf -i. See:
    -- https://github.com/commercialhaskell/stack/issues/3534
    ensureConfigureScript pkgDir

  when needConfig $ do
    deleteCaches pkgDir
    announce
    cp <- view compilerPathsL
    let (GhcPkgExe pkgPath) = cpPkg cp
    let programNames =
          case cpWhich cp of
            Ghc ->
              [ ("ghc", toFilePath (cpCompiler cp))
              , ("ghc-pkg", toFilePath pkgPath)
              ]
    exes <- forM programNames $ \(name, file) -> do
      mpath <- findExecutable file
      pure $ case mpath of
          Left _ -> []
          Right x -> pure $ concat ["--with-", name, "=", x]
    -- Configure cabal with arguments determined by
    -- Stack.Types.Build.configureOpts
    cabal KeepTHLoading $ "configure" : concat
      [ concat exes
      , dirs
      , nodirs
      ]
    -- Only write the cache for local packages.  Remote packages are built in a
    -- temporary directory so the cache would never be used anyway.
    case taskType task of
      TTLocalMutable{} -> writeConfigCache pkgDir newConfigCache
      TTRemotePackage{} -> pure ()
    writeCabalMod pkgDir newCabalMod
    -- This file gets updated one more time by the configure step, so get the
    -- most recent value. We could instead change our logic above to check if
    -- our config mod file is newer than the file above, but this seems
    -- reasonable too.
    getNewSetupConfigMod >>= writeSetupConfigMod pkgDir
    writePackageProjectRoot pkgDir newProjectRoot
  pure needConfig

-- | Make a padded prefix for log messages
packageNamePrefix :: ExecuteEnv -> PackageName -> String
packageNamePrefix ee name' =
  let name = packageNameString name'
      paddedName =
        case eeLargestPackageName ee of
          Nothing -> name
          Just len ->
            assert (len >= length name) $ take len $ name ++ L.repeat ' '
  in  paddedName <> "> "

announceTask ::
     HasLogFunc env
  => ExecuteEnv
  -> TaskType
  -> Utf8Builder
  -> RIO env ()
announceTask ee taskType action = logInfo $
     fromString
       (packageNamePrefix ee (pkgName (taskTypePackageIdentifier taskType)))
  <> action

prettyAnnounceTask ::
     HasTerm env
  => ExecuteEnv
  -> TaskType
  -> StyleDoc
  -> RIO env ()
prettyAnnounceTask ee taskType action = prettyInfo $
     fromString
       (packageNamePrefix ee (pkgName (taskTypePackageIdentifier taskType)))
  <> action

-- | Ensure we're the only action using the directory.  See
-- <https://github.com/commercialhaskell/stack/issues/2730>
withLockedDistDir ::
     forall env a. HasEnvConfig env
  => (StyleDoc -> RIO env ()) -- ^ A pretty announce function
  -> Path Abs Dir -- ^ root directory for package
  -> RIO env a
  -> RIO env a
withLockedDistDir announce root inner = do
  distDir <- distRelativeDir
  let lockFP = root </> distDir </> relFileBuildLock
  ensureDir $ parent lockFP

  mres <-
    withRunInIO $ \run ->
    withTryFileLock (toFilePath lockFP) Exclusive $ \_lock ->
    run inner

  case mres of
    Just res -> pure res
    Nothing -> do
      let complainer :: Companion (RIO env)
          complainer delay = do
            delay 5000000 -- 5 seconds
            announce $ fillSep
              [ flow "blocking for directory lock on"
              , pretty lockFP
              ]
            forever $ do
              delay 30000000 -- 30 seconds
              announce $ fillSep
                [ flow "still blocking for directory lock on"
                , pretty lockFP <> ";"
                , flow "maybe another Stack process is running?"
                ]
      withCompanion complainer $
        \stopComplaining ->
          withRunInIO $ \run ->
            withFileLock (toFilePath lockFP) Exclusive $ \_ ->
              run $ stopComplaining *> inner

-- | How we deal with output from GHC, either dumping to a log file or the
-- console (with some prefix).
data OutputType
  = OTLogFile !(Path Abs File) !Handle
  | OTConsole !(Maybe Utf8Builder)

-- | This sets up a context for executing build steps which need to run
-- Cabal (via a compiled Setup.hs).  In particular it does the following:
--
-- * Ensures the package exists in the file system, downloading if necessary.
--
-- * Opens a log file if the built output shouldn't go to stderr.
--
-- * Ensures that either a simple Setup.hs is built, or the package's
--   custom setup is built.
--
-- * Provides the user a function with which run the Cabal process.
withSingleContext ::
     forall env a. HasEnvConfig env
  => ActionContext
  -> ExecuteEnv
  -> TaskType
  -> Map PackageIdentifier GhcPkgId
     -- ^ All dependencies' package ids to provide to Setup.hs.
  -> Maybe String
  -> (  Package        -- Package info
     -> Path Abs File  -- Cabal file path
     -> Path Abs Dir   -- Package root directory file path
        -- Note that the `Path Abs Dir` argument is redundant with the
        -- `Path Abs File` argument, but we provide both to avoid recalculating
        -- `parent` of the `File`.
     -> (KeepOutputOpen -> ExcludeTHLoading -> [String] -> RIO env ())
        -- Function to run Cabal with args
     -> (Utf8Builder -> RIO env ())
        -- An plain 'announce' function, for different build phases
     -> OutputType
     -> RIO env a)
  -> RIO env a
withSingleContext
    ActionContext {..}
    ee@ExecuteEnv {..}
    taskType
    allDeps
    msuffix
    inner0
  = withPackage $ \package cabalfp pkgDir ->
      withOutputType pkgDir package $ \outputType ->
        withCabal package pkgDir outputType $ \cabal ->
          inner0 package cabalfp pkgDir cabal announce outputType
 where
  pkgId = taskTypePackageIdentifier taskType
  announce = announceTask ee taskType
  prettyAnnounce = prettyAnnounceTask ee taskType

  wanted =
    case taskType of
      TTLocalMutable lp -> lpWanted lp
      TTRemotePackage{} -> False

  -- Output to the console if this is the last task, and the user asked to build
  -- it specifically. When the action is a 'ConcurrencyDisallowed' action
  -- (benchmarks), then we can also be sure to have exclusive access to the
  -- console, so output is also sent to the console in this case.
  --
  -- See the discussion on #426 for thoughts on sending output to the console
  --from concurrent tasks.
  console =
       (  wanted
       && all
            (\(ActionId ident _) -> ident == pkgId)
            (Set.toList acRemaining)
       && eeTotalWanted == 1
       )
    || acConcurrency == ConcurrencyDisallowed

  withPackage inner =
    case taskType of
      TTLocalMutable lp -> do
        let root = parent $ lpCabalFile lp
        withLockedDistDir prettyAnnounce root $
          inner (lpPackage lp) (lpCabalFile lp) root
      TTRemotePackage _ package pkgloc -> do
        suffix <-
          parseRelDir $ packageIdentifierString $ packageIdentifier package
        let dir = eeTempDir </> suffix
        unpackPackageLocation dir pkgloc

        -- See: https://github.com/commercialhaskell/stack/issues/157
        distDir <- distRelativeDir
        let oldDist = dir </> relDirDist
            newDist = dir </> distDir
        exists <- doesDirExist oldDist
        when exists $ do
          -- Previously used takeDirectory, but that got confused
          -- by trailing slashes, see:
          -- https://github.com/commercialhaskell/stack/issues/216
          --
          -- Instead, use Path which is a bit more resilient
          ensureDir $ parent newDist
          renameDir oldDist newDist

        let name = pkgName pkgId
        cabalfpRel <- parseRelFile $ packageNameString name ++ ".cabal"
        let cabalfp = dir </> cabalfpRel
        inner package cabalfp dir

  withOutputType pkgDir package inner
    -- Not in interleaved mode. When building a single wanted package, dump
    -- to the console with no prefix.
    | console = inner $ OTConsole Nothing

    -- If the user requested interleaved output, dump to the console with a
    -- prefix.
    | boptsInterleavedOutput eeBuildOpts = inner $
        OTConsole $ Just $ fromString (packageNamePrefix ee $ packageName package)

    -- Neither condition applies, dump to a file.
    | otherwise = do
        logPath <- buildLogPath package msuffix
        ensureDir (parent logPath)
        let fp = toFilePath logPath

        -- We only want to dump logs for local non-dependency packages
        case taskType of
          TTLocalMutable lp | lpWanted lp ->
              liftIO $ atomically $ writeTChan eeLogFiles (pkgDir, logPath)
          _ -> pure ()

        withBinaryFile fp WriteMode $ \h -> inner $ OTLogFile logPath h

  withCabal ::
       Package
    -> Path Abs Dir
    -> OutputType
    -> (  (KeepOutputOpen -> ExcludeTHLoading -> [String] -> RIO env ())
       -> RIO env a
       )
    -> RIO env a
  withCabal package pkgDir outputType inner = do
    config <- view configL
    unless (configAllowDifferentUser config) $
      checkOwnership (pkgDir </> configWorkDir config)
    let envSettings = EnvSettings
          { esIncludeLocals = taskTypeLocation taskType == Local
          , esIncludeGhcPackagePath = False
          , esStackExe = False
          , esLocaleUtf8 = True
          , esKeepGhcRts = False
          }
    menv <- liftIO $ configProcessContextSettings config envSettings
    distRelativeDir' <- distRelativeDir
    esetupexehs <-
      -- Avoid broken Setup.hs files causing problems for simple build
      -- types, see:
      -- https://github.com/commercialhaskell/stack/issues/370
      case (packageBuildType package, eeSetupExe) of
        (C.Simple, Just setupExe) -> pure $ Left setupExe
        _ -> liftIO $ Right <$> getSetupHs pkgDir
    inner $ \keepOutputOpen stripTHLoading args -> do
      let cabalPackageArg
            -- Omit cabal package dependency when building
            -- Cabal. See
            -- https://github.com/commercialhaskell/stack/issues/1356
            | packageName package == mkPackageName "Cabal" = []
            | otherwise =
                ["-package=" ++ packageIdentifierString
                                    (PackageIdentifier cabalPackageName
                                                      eeCabalPkgVer)]
          packageDBArgs =
            ( "-clear-package-db"
            : "-global-package-db"
            : map
                (("-package-db=" ++) . toFilePathNoTrailingSep)
                (bcoExtraDBs eeBaseConfigOpts)
            ) ++
            ( (  "-package-db="
              ++ toFilePathNoTrailingSep (bcoSnapDB eeBaseConfigOpts)
              )
            : (  "-package-db="
              ++ toFilePathNoTrailingSep (bcoLocalDB eeBaseConfigOpts)
              )
            : ["-hide-all-packages"]
            )

          warnCustomNoDeps :: RIO env ()
          warnCustomNoDeps =
            case (taskType, packageBuildType package) of
              (TTLocalMutable lp, C.Custom) | lpWanted lp ->
                prettyWarnL
                  [ flow "Package"
                  , fromPackageName $ packageName package
                  , flow "uses a custom Cabal build, but does not use a \
                         \custom-setup stanza"
                  ]
              _ -> pure ()

          getPackageArgs :: Path Abs Dir -> RIO env [String]
          getPackageArgs setupDir =
            case packageSetupDeps package of
              -- The package is using the Cabal custom-setup
              -- configuration introduced in Cabal 1.24. In
              -- this case, the package is providing an
              -- explicit list of dependencies, and we
              -- should simply use all of them.
              Just customSetupDeps -> do
                unless (Map.member (mkPackageName "Cabal") customSetupDeps) $
                  prettyWarnL
                    [ fromPackageName $ packageName package
                    , flow "has a setup-depends field, but it does not mention \
                           \a Cabal dependency. This is likely to cause build \
                           \errors."
                    ]
                matchedDeps <-
                  forM (Map.toList customSetupDeps) $ \(name, depValue) -> do
                    let matches (PackageIdentifier name' version) =
                             name == name'
                          && version `withinRange` dvVersionRange depValue
                    case filter (matches . fst) (Map.toList allDeps) of
                      x:xs -> do
                        unless (null xs) $
                          prettyWarnL
                            [ flow "Found multiple installed packages for \
                                   \custom-setup dep:"
                            , style Current (fromPackageName name) <> "."
                            ]
                        pure ("-package-id=" ++ ghcPkgIdString (snd x), Just (fst x))
                      [] -> do
                        prettyWarnL
                          [ flow "Could not find custom-setup dep:"
                          , style Current (fromPackageName name) <> "."
                          ]
                        pure ("-package=" ++ packageNameString name, Nothing)
                let depsArgs = map fst matchedDeps
                -- Generate setup_macros.h and provide it to ghc
                let macroDeps = mapMaybe snd matchedDeps
                    cppMacrosFile = setupDir </> relFileSetupMacrosH
                    cppArgs =
                      ["-optP-include", "-optP" ++ toFilePath cppMacrosFile]
                writeBinaryFileAtomic
                  cppMacrosFile
                  ( encodeUtf8Builder
                      ( T.pack
                          ( C.generatePackageVersionMacros
                              (packageVersion package)
                              macroDeps
                          )
                      )
                  )
                pure (packageDBArgs ++ depsArgs ++ cppArgs)

              -- This branch is usually taken for builds, and is always taken
              -- for `stack sdist`.
              --
              -- This approach is debatable. It adds access to the snapshot
              -- package database for Cabal. There are two possible objections:
              --
              -- 1. This doesn't isolate the build enough; arbitrary other
              -- packages available could cause the build to succeed or fail.
              --
              -- 2. This doesn't provide enough packages: we should also
              -- include the local database when building local packages.
              --
              -- Currently, this branch is only taken via `stack sdist` or when
              -- explicitly requested in the stack.yaml file.
              Nothing -> do
                warnCustomNoDeps
                pure $
                     cabalPackageArg
                      -- NOTE: This is different from packageDBArgs above in
                      -- that it does not include the local database and does
                      -- not pass in the -hide-all-packages argument
                  ++ ( "-clear-package-db"
                     : "-global-package-db"
                     : map
                         (("-package-db=" ++) . toFilePathNoTrailingSep)
                         (bcoExtraDBs eeBaseConfigOpts)
                     ++ [    "-package-db="
                          ++ toFilePathNoTrailingSep (bcoSnapDB eeBaseConfigOpts)
                        ]
                     )

          setupArgs =
            ("--builddir=" ++ toFilePathNoTrailingSep distRelativeDir') : args

          runExe :: Path Abs File -> [String] -> RIO env ()
          runExe exeName fullArgs = do
            compilerVer <- view actualCompilerVersionL
            runAndOutput compilerVer `catch` \ece -> do
              (mlogFile, bss) <-
                case outputType of
                  OTConsole _ -> pure (Nothing, [])
                  OTLogFile logFile h ->
                    if keepOutputOpen == KeepOpen
                    then
                      pure (Nothing, []) -- expected failure build continues further
                    else do
                      liftIO $ hClose h
                      fmap (Just logFile,) $ withSourceFile (toFilePath logFile) $
                        \src ->
                             runConduit
                           $ src
                          .| CT.decodeUtf8Lenient
                          .| mungeBuildOutput
                               stripTHLoading makeAbsolute pkgDir compilerVer
                          .| CL.consume
              prettyThrowM $ CabalExitedUnsuccessfully
                (eceExitCode ece) pkgId exeName fullArgs mlogFile bss
           where
            runAndOutput :: ActualCompiler -> RIO env ()
            runAndOutput compilerVer = withWorkingDir (toFilePath pkgDir) $
              withProcessContext menv $ case outputType of
                OTLogFile _ h -> do
                  let prefixWithTimestamps =
                        if configPrefixTimestamps config
                          then PrefixWithTimestamps
                          else WithoutTimestamps
                  void $ sinkProcessStderrStdout (toFilePath exeName) fullArgs
                    (sinkWithTimestamps prefixWithTimestamps h)
                    (sinkWithTimestamps prefixWithTimestamps h)
                OTConsole mprefix ->
                  let prefix = fromMaybe mempty mprefix
                  in  void $ sinkProcessStderrStdout
                        (toFilePath exeName)
                        fullArgs
                        (outputSink KeepTHLoading LevelWarn compilerVer prefix)
                        (outputSink stripTHLoading LevelInfo compilerVer prefix)
            outputSink ::
                 HasCallStack
              => ExcludeTHLoading
              -> LogLevel
              -> ActualCompiler
              -> Utf8Builder
              -> ConduitM S.ByteString Void (RIO env) ()
            outputSink excludeTH level compilerVer prefix =
              CT.decodeUtf8Lenient
              .| mungeBuildOutput excludeTH makeAbsolute pkgDir compilerVer
              .| CL.mapM_ (logGeneric "" level . (prefix <>) . display)
            -- If users want control, we should add a config option for this
            makeAbsolute :: ConvertPathsToAbsolute
            makeAbsolute = case stripTHLoading of
              ExcludeTHLoading -> ConvertPathsToAbsolute
              KeepTHLoading    -> KeepPathsAsIs

      exeName <- case esetupexehs of
        Left setupExe -> pure setupExe
        Right setuphs -> do
          distDir <- distDirFromDir pkgDir
          let setupDir = distDir </> relDirSetup
              outputFile = setupDir </> relFileSetupLower
          customBuilt <- liftIO $ readIORef eeCustomBuilt
          if Set.member (packageName package) customBuilt
            then pure outputFile
            else do
              ensureDir setupDir
              compilerPath <- view $ compilerPathsL.to cpCompiler
              packageArgs <- getPackageArgs setupDir
              runExe compilerPath $
                [ "--make"
                , "-odir", toFilePathNoTrailingSep setupDir
                , "-hidir", toFilePathNoTrailingSep setupDir
                , "-i", "-i."
                ] ++ packageArgs ++
                [ toFilePath setuphs
                , toFilePath eeSetupShimHs
                , "-main-is"
                , "StackSetupShim.mainOverride"
                , "-o", toFilePath outputFile
                , "-threaded"
                ] ++

                -- Apply GHC options
                -- https://github.com/commercialhaskell/stack/issues/4526
                map
                  T.unpack
                  ( Map.findWithDefault
                      []
                      AGOEverything
                      (configGhcOptionsByCat config)
                  ++ case configApplyGhcOptions config of
                       AGOEverything -> boptsCLIGhcOptions eeBuildOptsCLI
                       AGOTargets -> []
                       AGOLocals -> []
                  )

              liftIO $ atomicModifyIORef' eeCustomBuilt $
                \oldCustomBuilt ->
                  (Set.insert (packageName package) oldCustomBuilt, ())
              pure outputFile
      let cabalVerboseArg =
            let CabalVerbosity cv = boptsCabalVerbose eeBuildOpts
            in  "--verbose=" <> showForCabal cv
      runExe exeName $ cabalVerboseArg:setupArgs

-- Implements running a package's build, used to implement 'ATBuild' and
-- 'ATBuildFinal' tasks.  In particular this does the following:
--
-- * Checks if the package exists in the precompiled cache, and if so,
--   add it to the database instead of performing the build.
--
-- * Runs the configure step if needed ('ensureConfig')
--
-- * Runs the build step
--
-- * Generates haddocks
--
-- * Registers the library and copies the built executables into the
--   local install directory. Note that this is literally invoking Cabal
--   with @copy@, and not the copying done by @stack install@ - that is
--   handled by 'copyExecutables'.
singleBuild :: forall env. (HasEnvConfig env, HasRunner env)
            => ActionContext
            -> ExecuteEnv
            -> Task
            -> InstalledMap
            -> Bool             -- ^ Is this a final build?
            -> RIO env ()
singleBuild
    ac@ActionContext {..}
    ee@ExecuteEnv {..}
    task@Task {..}
    installedMap
    isFinalBuild
  = do
    (allDepsMap, cache) <-
      getConfigCache ee task installedMap enableTests enableBenchmarks
    mprecompiled <- getPrecompiled cache
    minstalled <-
      case mprecompiled of
        Just precompiled -> copyPreCompiled precompiled
        Nothing -> do
          mcurator <- view $ buildConfigL.to bcCurator
          realConfigAndBuild cache mcurator allDepsMap
    case minstalled of
      Nothing -> pure ()
      Just installed -> do
        writeFlagCache installed cache
        liftIO $ atomically $
          modifyTVar eeGhcPkgIds $ Map.insert pkgId installed
 where
  pkgId = taskProvides task
  PackageIdentifier pname pversion = pkgId
  doHaddock mcurator package =
       taskBuildHaddock
    && not isFinalBuild
       -- Works around haddock failing on bytestring-builder since it has no
       -- modules when bytestring is new enough.
    && mainLibraryHasExposedModules package
       -- Special help for the curator tool to avoid haddocks that are known
       -- to fail
    && maybe True (Set.notMember pname . curatorSkipHaddock) mcurator
  expectHaddockFailure =
      maybe False (Set.member pname . curatorExpectHaddockFailure)
  isHaddockForHackage = boptsHaddockForHackage eeBuildOpts
  fulfillHaddockExpectations mcurator action
    | expectHaddockFailure mcurator = do
        eres <- tryAny $ action KeepOpen
        case eres of
          Right () -> prettyWarnL
            [ style Current (fromPackageName pname) <> ":"
            , flow "unexpected Haddock success."
            ]
          Left _ -> pure ()
  fulfillHaddockExpectations _ action = action CloseOnException

  buildingFinals = isFinalBuild || taskAllInOne
  enableTests = buildingFinals && any isCTest (taskComponents task)
  enableBenchmarks = buildingFinals && any isCBench (taskComponents task)

  annSuffix executableBuildStatuses =
    if result == "" then "" else " (" <> result <> ")"
   where
    result = T.intercalate " + " $ concat
      [ ["lib" | taskAllInOne && hasLib]
      , ["sub-lib" | taskAllInOne && hasSubLib]
      , ["exe" | taskAllInOne && hasExe]
      , ["test" | enableTests]
      , ["bench" | enableBenchmarks]
      ]
    (hasLib, hasSubLib, hasExe) = case taskType of
      TTLocalMutable lp ->
        let package = lpPackage lp
            hasLibrary = hasBuildableMainLibrary package
            hasSubLibraries = not . null $ packageSubLibraries package
            hasExecutables =
              not . Set.null $ exesToBuild executableBuildStatuses lp
        in  (hasLibrary, hasSubLibraries, hasExecutables)
      -- This isn't true, but we don't want to have this info for upstream deps.
      _ -> (False, False, False)

  getPrecompiled cache =
    case taskType of
      TTRemotePackage Immutable _ loc -> do
        mpc <- readPrecompiledCache
                 loc
                 (configCacheOpts cache)
                 (configCacheHaddock cache)
        case mpc of
          Nothing -> pure Nothing
          -- Only pay attention to precompiled caches that refer to packages
          -- within the snapshot.
          Just pc
            | maybe False
                (bcoSnapInstallRoot eeBaseConfigOpts `isProperPrefixOf`)
                (pcLibrary pc) -> pure Nothing
          -- If old precompiled cache files are left around but snapshots are
          -- deleted, it is possible for the precompiled file to refer to the
          -- very library we're building, and if flags are changed it may try to
          -- copy the library to itself. This check prevents that from
          -- happening.
          Just pc -> do
            let allM _ [] = pure True
                allM f (x:xs) = do
                  b <- f x
                  if b then allM f xs else pure False
            b <- liftIO $
                   allM doesFileExist $ maybe id (:) (pcLibrary pc) $ pcExes pc
            pure $ if b then Just pc else Nothing
      _ -> pure Nothing

  copyPreCompiled (PrecompiledCache mlib subLibs exes) = do
    announceTask ee taskType "using precompiled package"

    -- We need to copy .conf files for the main library and all sub-libraries
    -- which exist in the cache, from their old snapshot to the new one.
    -- However, we must unregister any such library in the new snapshot, in case
    -- it was built with different flags.
    let
      subLibNames = Set.toList $ buildableSubLibs $ case taskType of
        TTLocalMutable lp -> lpPackage lp
        TTRemotePackage _ p _ -> p
      toMungedPackageId :: Text -> MungedPackageId
      toMungedPackageId subLib =
        let subLibName = LSubLibName $ mkUnqualComponentName $ T.unpack subLib
        in  MungedPackageId (MungedPackageName pname subLibName) pversion
      toPackageId :: MungedPackageId -> PackageIdentifier
      toPackageId (MungedPackageId n v) =
        PackageIdentifier (encodeCompatPackageName n) v
      allToUnregister :: [Either PackageIdentifier GhcPkgId]
      allToUnregister = mcons
        (Left pkgId <$ mlib)
        (map (Left . toPackageId . toMungedPackageId) subLibNames)
      allToRegister = mcons mlib subLibs

    unless (null allToRegister) $
      withMVar eeInstallLock $ \() -> do
        -- We want to ignore the global and user package databases. ghc-pkg
        -- allows us to specify --no-user-package-db and --package-db=<db> on
        -- the command line.
        let pkgDb = bcoSnapDB eeBaseConfigOpts
        ghcPkgExe <- getGhcPkgExe
        -- First unregister, silently, everything that needs to be unregistered.
        case nonEmpty allToUnregister of
          Nothing -> pure ()
          Just allToUnregister' -> catchAny
            (unregisterGhcPkgIds False ghcPkgExe pkgDb allToUnregister')
            (const (pure ()))
        -- Now, register the cached conf files.
        forM_ allToRegister $ \libpath ->
          ghcPkg ghcPkgExe [pkgDb] ["register", "--force", toFilePath libpath]

    liftIO $ forM_ exes $ \exe -> do
      ensureDir bindir
      let dst = bindir </> filename exe
      createLink (toFilePath exe) (toFilePath dst) `catchIO` \_ -> copyFile exe dst
    case (mlib, exes) of
      (Nothing, _:_) -> markExeInstalled (taskLocation task) pkgId
      _ -> pure ()

    -- Find the package in the database
    let pkgDbs = [bcoSnapDB eeBaseConfigOpts]

    case mlib of
      Nothing -> pure $ Just $ Executable pkgId
      Just _ -> do
        mpkgid <- loadInstalledPkg pkgDbs eeSnapshotDumpPkgs pname

        pure $ Just $
          case mpkgid of
            Nothing -> assert False $ Executable pkgId
            Just pkgid -> simpleInstalledLib pkgId pkgid mempty
   where
    bindir = bcoSnapInstallRoot eeBaseConfigOpts </> bindirSuffix

  realConfigAndBuild cache mcurator allDepsMap =
    withSingleContext ac ee taskType allDepsMap Nothing $
      \package cabalfp pkgDir cabal0 announce _outputType -> do
        let cabal = cabal0 CloseOnException
        executableBuildStatuses <- getExecutableBuildStatuses package pkgDir
        when (  not (cabalIsSatisfied executableBuildStatuses)
             && taskIsTarget task
             ) $
          prettyInfoL
            [ flow "Building all executables for"
            , style Current (fromPackageName $ packageName package)
            , flow "once. After a successful build of all of them, only \
                   \specified executables will be rebuilt."
            ]
        _neededConfig <-
          ensureConfig
            cache
            pkgDir
            ee
            ( announce
                (  "configure"
                <> display (annSuffix executableBuildStatuses)
                )
            )
            cabal
            cabalfp
            task
        let installedMapHasThisPkg :: Bool
            installedMapHasThisPkg =
              case Map.lookup (packageName package) installedMap of
                Just (_, Library ident _) -> ident == pkgId
                Just (_, Executable _) -> True
                _ -> False

        case ( boptsCLIOnlyConfigure eeBuildOptsCLI
             , boptsCLIInitialBuildSteps eeBuildOptsCLI && taskIsTarget task) of
          -- A full build is done if there are downstream actions,
          -- because their configure step will require that this
          -- package is built. See
          -- https://github.com/commercialhaskell/stack/issues/2787
          (True, _) | null acDownstream -> pure Nothing
          (_, True) | null acDownstream || installedMapHasThisPkg -> do
            initialBuildSteps executableBuildStatuses cabal announce
            pure Nothing
          _ -> fulfillCuratorBuildExpectations
                 pname
                 mcurator
                 enableTests
                 enableBenchmarks
                 Nothing
                 (Just <$>
                    realBuild cache package pkgDir cabal0 announce executableBuildStatuses)

  initialBuildSteps executableBuildStatuses cabal announce = do
    announce
      (  "initial-build-steps"
      <> display (annSuffix executableBuildStatuses)
      )
    cabal KeepTHLoading ["repl", "stack-initial-build-steps"]

  realBuild ::
       ConfigCache
    -> Package
    -> Path Abs Dir
    -> (KeepOutputOpen -> ExcludeTHLoading -> [String] -> RIO env ())
    -> (Utf8Builder -> RIO env ())
       -- ^ A plain 'announce' function
    -> Map Text ExecutableBuildStatus
    -> RIO env Installed
  realBuild cache package pkgDir cabal0 announce executableBuildStatuses = do
    let cabal = cabal0 CloseOnException
    wc <- view $ actualCompilerVersionL.whichCompilerL

    markExeNotInstalled (taskLocation task) pkgId
    case taskType of
      TTLocalMutable lp -> do
        when enableTests $ setTestStatus pkgDir TSUnknown
        caches <- runMemoizedWith $ lpNewBuildCaches lp
        mapM_
          (uncurry (writeBuildCache pkgDir))
          (Map.toList caches)
      TTRemotePackage{} -> pure ()

    -- FIXME: only output these if they're in the build plan.

    let postBuildCheck _succeeded = do
          mlocalWarnings <- case taskType of
            TTLocalMutable lp -> do
                warnings <- checkForUnlistedFiles taskType pkgDir
                -- TODO: Perhaps only emit these warnings for non extra-dep?
                pure (Just (lpCabalFile lp, warnings))
            _ -> pure Nothing
          -- NOTE: once
          -- https://github.com/commercialhaskell/stack/issues/2649
          -- is resolved, we will want to partition the warnings
          -- based on variety, and output in different lists.
          let showModuleWarning (UnlistedModulesWarning comp modules) =
                "- In" <+>
                fromString (T.unpack (renderComponent comp)) <>
                ":" <> line <>
                indent 4 ( mconcat
                         $ L.intersperse line
                         $ map
                             (style Good . fromString . C.display)
                             modules
                         )
          forM_ mlocalWarnings $ \(cabalfp, warnings) ->
            unless (null warnings) $ prettyWarn $
                 flow "The following modules should be added to \
                      \exposed-modules or other-modules in" <+>
                      pretty cabalfp
              <> ":"
              <> line
              <> indent 4 ( mconcat
                          $ L.intersperse line
                          $ map showModuleWarning warnings
                          )
              <> blankLine
              <> flow "Missing modules in the Cabal file are likely to cause \
                      \undefined reference errors from the linker, along with \
                      \other problems."

    actualCompiler <- view actualCompilerVersionL
    () <- announce
      (  "build"
      <> display (annSuffix executableBuildStatuses)
      <> " with "
      <> display actualCompiler
      )
    config <- view configL
    extraOpts <- extraBuildOptions wc eeBuildOpts
    let stripTHLoading
          | configHideTHLoading config = ExcludeTHLoading
          | otherwise                  = KeepTHLoading
    cabal stripTHLoading (("build" :) $ (++ extraOpts) $
        case (taskType, taskAllInOne, isFinalBuild) of
            (_, True, True) -> throwM AllInOneBuildBug
            (TTLocalMutable lp, False, False) ->
              primaryComponentOptions executableBuildStatuses lp
            (TTLocalMutable lp, False, True) -> finalComponentOptions lp
            (TTLocalMutable lp, True, False) ->
                 primaryComponentOptions executableBuildStatuses lp
              ++ finalComponentOptions lp
            (TTRemotePackage{}, _, _) -> [])
      `catch` \ex -> case ex of
        CabalExitedUnsuccessfully{} ->
          postBuildCheck False >> prettyThrowM ex
        _ -> throwM ex
    postBuildCheck True

    mcurator <- view $ buildConfigL.to bcCurator
    when (doHaddock mcurator package) $ do
      announce $ if isHaddockForHackage
        then "haddock for Hackage"
        else "haddock"

      -- For GHC 8.4 and later, provide the --quickjump option.
      let quickjump =
            case actualCompiler of
              ACGhc ghcVer
                | ghcVer >= mkVersion [8, 4] -> ["--haddock-option=--quickjump"]
              _ -> []

      fulfillHaddockExpectations mcurator $ \keep -> do
        let args = concat
              (  if isHaddockForHackage
                   then
                     [ [ "--for-hackage" ] ]
                   else
                     [ [ "--html"
                       , "--hoogle"
                       , "--html-location=../$pkg-$version/"
                       ]
                     , [ "--haddock-option=--hyperlinked-source"
                       | boptsHaddockHyperlinkSource eeBuildOpts
                       ]
                     , [ "--internal" | boptsHaddockInternal eeBuildOpts ]
                     , quickjump
                     ]
              <> [ [ "--haddock-option=" <> opt
                   | opt <- hoAdditionalArgs (boptsHaddockOpts eeBuildOpts)
                   ]
                 ]
              )

        cabal0 keep KeepTHLoading $ "haddock" : args

    let hasLibrary = hasBuildableMainLibrary package
        hasSubLibraries = not $ null $ packageSubLibraries package
        hasExecutables = not $ null $ packageExecutables package
        shouldCopy =
             not isFinalBuild
          && (hasLibrary || hasSubLibraries || hasExecutables)
    when shouldCopy $ withMVar eeInstallLock $ \() -> do
      announce "copy/register"
      eres <- try $ cabal KeepTHLoading ["copy"]
      case eres of
        Left err@CabalExitedUnsuccessfully{} ->
          throwM $ CabalCopyFailed
                     (packageBuildType package == C.Simple)
                     (displayException err)
        _ -> pure ()
      when (hasLibrary || hasSubLibraries) $ cabal KeepTHLoading ["register"]

    -- copy ddump-* files
    case T.unpack <$> boptsDdumpDir eeBuildOpts of
      Just ddumpPath | buildingFinals && not (null ddumpPath) -> do
        distDir <- distRelativeDir
        ddumpDir <- parseRelDir ddumpPath

        logDebug $ fromString ("ddump-dir: " <> toFilePath ddumpDir)
        logDebug $ fromString ("dist-dir: " <> toFilePath distDir)

        runConduitRes
          $ CF.sourceDirectoryDeep False (toFilePath distDir)
         .| CL.filter (L.isInfixOf ".dump-")
         .| CL.mapM_ (\src -> liftIO $ do
              parentDir <- parent <$> parseRelDir src
              destBaseDir <-
                (ddumpDir </>) <$> stripProperPrefix distDir parentDir
              -- exclude .stack-work dir
              unless (".stack-work" `L.isInfixOf` toFilePath destBaseDir) $ do
                ensureDir destBaseDir
                src' <- parseRelFile src
                copyFile src' (destBaseDir </> filename src'))
      _ -> pure ()

    let (installedPkgDb, installedDumpPkgsTVar) =
          case taskLocation task of
            Snap ->
              ( bcoSnapDB eeBaseConfigOpts
              , eeSnapshotDumpPkgs )
            Local ->
              ( bcoLocalDB eeBaseConfigOpts
              , eeLocalDumpPkgs )
    let ident = PackageIdentifier (packageName package) (packageVersion package)
    -- only pure the sub-libraries to cache them if we also cache the main
    -- library (that is, if it exists)
    (mpkgid, subLibsPkgIds) <- if hasBuildableMainLibrary package
      then do
        subLibsPkgIds' <- fmap catMaybes $
          forM (getBuildableListAs id $ packageSubLibraries package) $ \subLib -> do
            let subLibName = toCabalMungedPackageName (packageName package) subLib
            maybeGhcpkgId <- loadInstalledPkg
              [installedPkgDb]
              installedDumpPkgsTVar
              (encodeCompatPackageName subLibName)
            pure $ (subLib, ) <$> maybeGhcpkgId
        let subLibsPkgIds = snd <$> subLibsPkgIds'
        mpkgid <- loadInstalledPkg
                    [installedPkgDb]
                    installedDumpPkgsTVar
                    (packageName package)
        let makeInstalledLib pkgid = simpleInstalledLib ident pkgid (Map.fromList subLibsPkgIds')
        case mpkgid of
          Nothing -> throwM $ Couldn'tFindPkgId $ packageName package
          Just pkgid -> pure (makeInstalledLib pkgid, subLibsPkgIds)
      else do
        markExeInstalled (taskLocation task) pkgId -- TODO unify somehow
                                                   -- with writeFlagCache?
        pure (Executable ident, []) -- don't pure sublibs in this case

    case taskType of
      TTRemotePackage Immutable _ loc ->
        writePrecompiledCache
          eeBaseConfigOpts
          loc
          (configCacheOpts cache)
          (configCacheHaddock cache)
          mpkgid
          subLibsPkgIds
          (buildableExes package)
      _ -> pure ()

    case taskType of
      -- For packages from a package index, pkgDir is in the tmp directory. We
      -- eagerly delete it if no other tasks require it, to reduce space usage
      -- in tmp (#3018).
      TTRemotePackage{} -> do
        let remaining =
              filter
                (\(ActionId x _) -> x == pkgId)
                (Set.toList acRemaining)
        when (null remaining) $ removeDirRecur pkgDir
      TTLocalMutable{} -> pure ()

    pure mpkgid

  loadInstalledPkg ::
       [Path Abs Dir]
    -> TVar (Map GhcPkgId DumpPackage)
    -> PackageName
    -> RIO env (Maybe GhcPkgId)
  loadInstalledPkg pkgDbs tvar name = do
    pkgexe <- getGhcPkgExe
    dps <- ghcPkgDescribe pkgexe name pkgDbs $ conduitDumpPackage .| CL.consume
    case dps of
      [] -> pure Nothing
      [dp] -> do
        liftIO $ atomically $ modifyTVar' tvar (Map.insert (dpGhcPkgId dp) dp)
        pure $ Just (dpGhcPkgId dp)
      _ -> throwM $ MultipleResultsBug name dps

-- | Get the build status of all the package executables. Do so by
-- testing whether their expected output file exists, e.g.
--
-- .stack-work/dist/x86_64-osx/Cabal-1.22.4.0/build/alpha/alpha
-- .stack-work/dist/x86_64-osx/Cabal-1.22.4.0/build/alpha/alpha.exe
-- .stack-work/dist/x86_64-osx/Cabal-1.22.4.0/build/alpha/alpha.jsexe/ (NOTE: a dir)
getExecutableBuildStatuses ::
     HasEnvConfig env
  => Package
  -> Path Abs Dir
  -> RIO env (Map Text ExecutableBuildStatus)
getExecutableBuildStatuses package pkgDir = do
  distDir <- distDirFromDir pkgDir
  platform <- view platformL
  fmap
    Map.fromList
    (mapM (checkExeStatus platform distDir) (Set.toList (buildableExes package)))

-- | Check whether the given executable is defined in the given dist directory.
checkExeStatus ::
     HasLogFunc env
  => Platform
  -> Path b Dir
  -> Text
  -> RIO env (Text, ExecutableBuildStatus)
checkExeStatus platform distDir name = do
  exename <- parseRelDir (T.unpack name)
  exists <- checkPath (distDir </> relDirBuild </> exename)
  pure
    ( name
    , if exists
        then ExecutableBuilt
        else ExecutableNotBuilt)
 where
  checkPath base =
    case platform of
      Platform _ Windows -> do
        fileandext <- parseRelFile (file ++ ".exe")
        doesFileExist (base </> fileandext)
      _ -> do
        fileandext <- parseRelFile file
        doesFileExist (base </> fileandext)
   where
    file = T.unpack name

-- | Check if any unlisted files have been found, and add them to the build cache.
checkForUnlistedFiles ::
     HasEnvConfig env
  => TaskType
  -> Path Abs Dir
  -> RIO env [PackageWarning]
checkForUnlistedFiles (TTLocalMutable lp) pkgDir = do
  caches <- runMemoizedWith $ lpNewBuildCaches lp
  (addBuildCache,warnings) <-
    addUnlistedToBuildCache
      (lpPackage lp)
      (lpCabalFile lp)
      (lpComponents lp)
      caches
  forM_ (Map.toList addBuildCache) $ \(component, newToCache) -> do
    let cache = Map.findWithDefault Map.empty component caches
    writeBuildCache pkgDir component $
      Map.unions (cache : newToCache)
  pure warnings
checkForUnlistedFiles TTRemotePackage{} _ = pure []

-- | Implements running a package's tests. Also handles producing
-- coverage reports if coverage is enabled.
singleTest :: HasEnvConfig env
           => TestOpts
           -> [Text]
           -> ActionContext
           -> ExecuteEnv
           -> Task
           -> InstalledMap
           -> RIO env ()
singleTest topts testsToRun ac ee task installedMap = do
  -- FIXME: Since this doesn't use cabal, we should be able to avoid using a
  -- full blown 'withSingleContext'.
  (allDepsMap, _cache) <- getConfigCache ee task installedMap True False
  mcurator <- view $ buildConfigL.to bcCurator
  let pname = pkgName $ taskProvides task
      expectFailure = expectTestFailure pname mcurator
  withSingleContext ac ee (taskType task) allDepsMap (Just "test") $
    \package _cabalfp pkgDir _cabal announce outputType -> do
      config <- view configL
      let needHpc = toCoverage topts

      toRun <-
        if toDisableRun topts
          then do
            announce "Test running disabled by --no-run-tests flag."
            pure False
          else if toRerunTests topts
            then pure True
            else do
              status <- getTestStatus pkgDir
              case status of
                TSSuccess -> do
                  unless (null testsToRun) $
                    announce "skipping already passed test"
                  pure False
                TSFailure
                  | expectFailure -> do
                      announce "skipping already failed test that's expected to fail"
                      pure False
                  | otherwise -> do
                      announce "rerunning previously failed test"
                      pure True
                TSUnknown -> pure True

      when toRun $ do
        buildDir <- distDirFromDir pkgDir
        hpcDir <- hpcDirFromDir pkgDir
        when needHpc (ensureDir hpcDir)

        let suitesToRun
              = [ testSuitePair
                | testSuitePair <-
                    (fmap . fmap) (getField @"interface") <$>
                      collectionKeyValueList $ packageTestSuites package
                , let testName = fst testSuitePair
                , testName `elem` testsToRun
                ]

        errs <- fmap Map.unions $ forM suitesToRun $ \(testName, suiteInterface) -> do
          let stestName = T.unpack testName
          (testName', isTestTypeLib) <-
            case suiteInterface of
              C.TestSuiteLibV09{} -> pure (stestName ++ "Stub", True)
              C.TestSuiteExeV10{} -> pure (stestName, False)
              interface -> throwM (TestSuiteTypeUnsupported interface)

          let exeName = testName' ++
                case configPlatform config of
                  Platform _ Windows -> ".exe"
                  _ -> ""
          tixPath <- fmap (pkgDir </>) $ parseRelFile $ exeName ++ ".tix"
          exePath <-
            fmap (buildDir </>) $ parseRelFile $
              "build/" ++ testName' ++ "/" ++ exeName
          exists <- doesFileExist exePath
          -- in Stack.Package.packageFromPackageDescription we filter out
          -- package itself of any dependencies so any tests requiring loading
          -- of their own package library will fail so to prevent this we return
          -- it back here but unfortunately unconditionally
          installed <- case Map.lookup pname installedMap of
            Just (_, installed) -> pure $ Just installed
            Nothing -> do
              idMap <- liftIO $ readTVarIO (eeGhcPkgIds ee)
              pure $ Map.lookup (taskProvides task) idMap
          let pkgGhcIdList = case installed of
                               Just (Library _ libInfo) -> [iliId libInfo]
                               _ -> []
          -- doctest relies on template-haskell in QuickCheck-based tests
          thGhcId <-
            case L.find ((== "template-haskell") . pkgName . dpPackageIdent. snd)
                   (Map.toList $ eeGlobalDumpPkgs ee) of
              Just (ghcId, _) -> pure ghcId
              Nothing -> throwIO TemplateHaskellNotFoundBug
          -- env variable GHC_ENVIRONMENT is set for doctest so module names for
          -- packages with proper dependencies should no longer get ambiguous
          -- see e.g. https://github.com/doctest/issues/119
          -- also we set HASKELL_DIST_DIR to a package dist directory so
          -- doctest will be able to load modules autogenerated by Cabal
          let setEnv f pc = modifyEnvVars pc $ \envVars ->
                Map.insert "HASKELL_DIST_DIR" (T.pack $ toFilePath buildDir) $
                Map.insert "GHC_ENVIRONMENT" (T.pack f) envVars
              fp' = eeTempDir ee </> testGhcEnvRelFile
          -- Add a random suffix to avoid conflicts between parallel jobs
          -- See https://github.com/commercialhaskell/stack/issues/5024
          randomInt <- liftIO (randomIO :: IO Int)
          let randomSuffix = "." <> show (abs randomInt)
          fp <- toFilePath <$> addExtension randomSuffix fp'
          let snapDBPath =
                toFilePathNoTrailingSep (bcoSnapDB $ eeBaseConfigOpts ee)
              localDBPath =
                toFilePathNoTrailingSep (bcoLocalDB $ eeBaseConfigOpts ee)
              ghcEnv =
                   "clear-package-db\n"
                <> "global-package-db\n"
                <> "package-db "
                <> fromString snapDBPath
                <> "\n"
                <> "package-db "
                <> fromString localDBPath
                <> "\n"
                <> foldMap
                     ( \ghcId ->
                            "package-id "
                         <> display (unGhcPkgId ghcId)
                         <> "\n"
                     )
                     (pkgGhcIdList ++ thGhcId:Map.elems allDepsMap)
          writeFileUtf8Builder fp ghcEnv
          menv <- liftIO $
            setEnv fp =<< configProcessContextSettings config EnvSettings
              { esIncludeLocals = taskLocation task == Local
              , esIncludeGhcPackagePath = True
              , esStackExe = True
              , esLocaleUtf8 = False
              , esKeepGhcRts = False
              }
          let emptyResult = Map.singleton testName Nothing
          withProcessContext menv $ if exists
            then do
                -- We clear out the .tix files before doing a run.
                when needHpc $ do
                  tixexists <- doesFileExist tixPath
                  when tixexists $
                    prettyWarnL
                      [ flow "Removing HPC file"
                      , pretty tixPath <> "."
                      ]
                  liftIO $ ignoringAbsence (removeFile tixPath)

                let args = toAdditionalArgs topts
                    argsDisplay = case args of
                      [] -> ""
                      _ ->    ", args: "
                           <> T.intercalate " " (map showProcessArgDebug args)
                announce $
                     "test (suite: "
                  <> display testName
                  <> display argsDisplay
                  <> ")"

                -- Clear "Progress: ..." message before
                -- redirecting output.
                case outputType of
                  OTConsole _ -> do
                    logStickyDone ""
                    liftIO $ hFlush stdout
                    liftIO $ hFlush stderr
                  OTLogFile _ _ -> pure ()

                let output = case outputType of
                      OTConsole Nothing -> Nothing <$ inherit
                      OTConsole (Just prefix) -> fmap
                        ( \src -> Just $
                               runConduit $ src
                            .| CT.decodeUtf8Lenient
                            .| CT.lines
                            .| CL.map stripCR
                            .| CL.mapM_ (\t -> logInfo $ prefix <> display t)
                        )
                        createSource
                      OTLogFile _ h -> Nothing <$ useHandleOpen h
                    optionalTimeout action
                      | Just maxSecs <- toMaximumTimeSeconds topts, maxSecs > 0 =
                          timeout (maxSecs * 1000000) action
                      | otherwise = Just <$> action

                mec <- withWorkingDir (toFilePath pkgDir) $
                  optionalTimeout $ proc (toFilePath exePath) args $ \pc0 -> do
                    changeStdin <-
                      if isTestTypeLib
                        then do
                          logPath <- buildLogPath package (Just stestName)
                          ensureDir (parent logPath)
                          pure $
                              setStdin
                            $ byteStringInput
                            $ BL.fromStrict
                            $ encodeUtf8 $ fromString $
                            show ( logPath
                                 , mkUnqualComponentName (T.unpack testName)
                                 )
                        else do
                          isTerminal <- view $ globalOptsL.to globalTerminal
                          if toAllowStdin topts && isTerminal
                            then pure id
                            else pure $ setStdin $ byteStringInput mempty
                    let pc = changeStdin
                           $ setStdout output
                           $ setStderr output
                             pc0
                    withProcessWait pc $ \p -> do
                      case (getStdout p, getStderr p) of
                        (Nothing, Nothing) -> pure ()
                        (Just x, Just y) -> concurrently_ x y
                        (x, y) -> assert False $
                          concurrently_
                            (fromMaybe (pure ()) x)
                            (fromMaybe (pure ()) y)
                      waitExitCode p
                -- Add a trailing newline, incase the test
                -- output didn't finish with a newline.
                case outputType of
                  OTConsole Nothing -> prettyInfo blankLine
                  _ -> pure ()
                -- Move the .tix file out of the package
                -- directory into the hpc work dir, for
                -- tidiness.
                when needHpc $
                  updateTixFile (packageName package) tixPath testName'
                let announceResult result =
                      announce $
                           "Test suite "
                        <> display testName
                        <> " "
                        <> result
                case mec of
                  Just ExitSuccess -> do
                    announceResult "passed"
                    pure Map.empty
                  Nothing -> do
                    announceResult "timed out"
                    if expectFailure
                    then pure Map.empty
                    else pure $ Map.singleton testName Nothing
                  Just ec -> do
                    announceResult "failed"
                    if expectFailure
                    then pure Map.empty
                    else pure $ Map.singleton testName (Just ec)
              else do
                unless expectFailure $
                  logError $
                    displayShow $ TestSuiteExeMissing
                      (packageBuildType package == C.Simple)
                      exeName
                      (packageNameString (packageName package))
                      (T.unpack testName)
                pure emptyResult

        when needHpc $ do
          let testsToRun' = map f testsToRun
              f tName =
                case getField @"interface" <$> mComponent of
                  Just C.TestSuiteLibV09{} -> tName <> "Stub"
                  _ -> tName
               where
                mComponent = collectionLookup tName (packageTestSuites package)
          generateHpcReport pkgDir package testsToRun'

        bs <- liftIO $
          case outputType of
            OTConsole _ -> pure ""
            OTLogFile logFile h -> do
              hClose h
              S.readFile $ toFilePath logFile

        let succeeded = Map.null errs
        unless (succeeded || expectFailure) $
          throwM $ TestSuiteFailure
            (taskProvides task)
            errs
            (case outputType of
               OTLogFile fp _ -> Just fp
               OTConsole _ -> Nothing)
            bs

        setTestStatus pkgDir $ if succeeded then TSSuccess else TSFailure

-- | Implements running a package's benchmarks.
singleBench :: HasEnvConfig env
            => BenchmarkOpts
            -> [Text]
            -> ActionContext
            -> ExecuteEnv
            -> Task
            -> InstalledMap
            -> RIO env ()
singleBench beopts benchesToRun ac ee task installedMap = do
  (allDepsMap, _cache) <- getConfigCache ee task installedMap False True
  withSingleContext ac ee (taskType task) allDepsMap (Just "bench") $
    \_package _cabalfp _pkgDir cabal announce _outputType -> do
      let args = map T.unpack benchesToRun <> maybe []
                       ((:[]) . ("--benchmark-options=" <>))
                       (beoAdditionalArgs beopts)

      toRun <-
        if beoDisableRun beopts
          then do
            announce "Benchmark running disabled by --no-run-benchmarks flag."
            pure False
          else pure True

      when toRun $ do
        announce "benchmarks"
        cabal CloseOnException KeepTHLoading ("bench" : args)

data ExcludeTHLoading
  = ExcludeTHLoading
  | KeepTHLoading

data ConvertPathsToAbsolute
  = ConvertPathsToAbsolute
  | KeepPathsAsIs

-- | special marker for expected failures in curator builds, using those we need
-- to keep log handle open as build continues further even after a failure
data KeepOutputOpen
  = KeepOpen
  | CloseOnException
  deriving Eq

-- | Strip Template Haskell "Loading package" lines and making paths absolute.
mungeBuildOutput ::
     forall m. (MonadIO m, MonadUnliftIO m)
  => ExcludeTHLoading       -- ^ exclude TH loading?
  -> ConvertPathsToAbsolute -- ^ convert paths to absolute?
  -> Path Abs Dir           -- ^ package's root directory
  -> ActualCompiler         -- ^ compiler we're building with
  -> ConduitM Text Text m ()
mungeBuildOutput excludeTHLoading makeAbsolute pkgDir compilerVer = void $
  CT.lines
  .| CL.map stripCR
  .| CL.filter (not . isTHLoading)
  .| filterLinkerWarnings
  .| toAbsolute
 where
  -- | Is this line a Template Haskell "Loading package" line
  -- ByteString
  isTHLoading :: Text -> Bool
  isTHLoading = case excludeTHLoading of
    KeepTHLoading    -> const False
    ExcludeTHLoading -> \bs ->
      "Loading package " `T.isPrefixOf` bs &&
      ("done." `T.isSuffixOf` bs || "done.\r" `T.isSuffixOf` bs)

  filterLinkerWarnings :: ConduitM Text Text m ()
  filterLinkerWarnings
    -- Check for ghc 7.8 since it's the only one prone to producing
    -- linker warnings on Windows x64
    | getGhcVersion compilerVer >= mkVersion [7, 8] = doNothing
    | otherwise = CL.filter (not . isLinkerWarning)

  isLinkerWarning :: Text -> Bool
  isLinkerWarning str =
       (  "ghc.exe: warning:" `T.isPrefixOf` str
       || "ghc.EXE: warning:" `T.isPrefixOf` str
       )
    && "is linked instead of __imp_" `T.isInfixOf` str

  -- | Convert GHC error lines with file paths to have absolute file paths
  toAbsolute :: ConduitM Text Text m ()
  toAbsolute = case makeAbsolute of
    KeepPathsAsIs          -> doNothing
    ConvertPathsToAbsolute -> CL.mapM toAbsolutePath

  toAbsolutePath :: Text -> m Text
  toAbsolutePath bs = do
    let (x, y) = T.break (== ':') bs
    mabs <-
      if isValidSuffix y
        then
          fmap (fmap ((T.takeWhile isSpace x <>) . T.pack . toFilePath)) $
            forgivingResolveFile pkgDir (T.unpack $ T.dropWhile isSpace x) `catch`
              \(_ :: PathException) -> pure Nothing
        else pure Nothing
    case mabs of
      Nothing -> pure bs
      Just fp -> pure $ fp `T.append` y

  doNothing :: ConduitM Text Text m ()
  doNothing = awaitForever yield

  -- | Match the error location format at the end of lines
  isValidSuffix = isRight . parseOnly lineCol
  lineCol = char ':'
    >> choice
         [ num >> char ':' >> num >> optional (char '-' >> num) >> pure ()
         , char '(' >> num >> char ',' >> num >> P.string ")-(" >> num >>
           char ',' >> num >> char ')' >> pure ()
         ]
    >> char ':'
    >> pure ()
   where
    num = some digit

-- | Whether to prefix log lines with timestamps.
data PrefixWithTimestamps
  = PrefixWithTimestamps
  | WithoutTimestamps

-- | Write stream of lines to handle, but adding timestamps.
sinkWithTimestamps ::
     MonadIO m
  => PrefixWithTimestamps
  -> Handle
  -> ConduitT ByteString Void m ()
sinkWithTimestamps prefixWithTimestamps h =
  case prefixWithTimestamps of
    PrefixWithTimestamps ->
      CB.lines .| CL.mapM addTimestamp .| CL.map (<> "\n") .| sinkHandle h
    WithoutTimestamps -> sinkHandle h
 where
  addTimestamp theLine = do
    now <- liftIO getZonedTime
    pure (formatZonedTimeForLog now <> " " <> theLine)

-- | Format a time in ISO8601 format. We choose ZonedTime over UTCTime
-- because a user expects to see logs in their local time, and would
-- be confused to see UTC time. Stack's debug logs also use the local
-- time zone.
formatZonedTimeForLog :: ZonedTime -> ByteString
formatZonedTimeForLog =
  S8.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%6Q"

-- | Find the Setup.hs or Setup.lhs in the given directory. If none exists,
-- throw an exception.
getSetupHs :: Path Abs Dir -- ^ project directory
           -> IO (Path Abs File)
getSetupHs dir = do
  exists1 <- doesFileExist fp1
  if exists1
    then pure fp1
    else do
      exists2 <- doesFileExist fp2
      if exists2
        then pure fp2
        else throwM $ NoSetupHsFound dir
 where
  fp1 = dir </> relFileSetupHs
  fp2 = dir </> relFileSetupLhs

-- Do not pass `-hpcdir` as GHC option if the coverage is not enabled.
-- This helps running stack-compiled programs with dynamic interpreters like
-- `hint`. Cfr: https://github.com/commercialhaskell/stack/issues/997
extraBuildOptions :: (HasEnvConfig env, HasRunner env)
                  => WhichCompiler -> BuildOpts -> RIO env [String]
extraBuildOptions wc bopts = do
  colorOpt <- appropriateGhcColorFlag
  let optsFlag = compilerOptionsCabalFlag wc
      baseOpts = maybe "" (" " ++) colorOpt
  if toCoverage (boptsTestOpts bopts)
    then do
      hpcIndexDir <- toFilePathNoTrailingSep <$> hpcRelativeDir
      pure [optsFlag, "-hpcdir " ++ hpcIndexDir ++ baseOpts]
    else
      pure [optsFlag, baseOpts]

-- Library, sub-library, foreign library and executable build components.
primaryComponentOptions ::
     Map Text ExecutableBuildStatus
  -> LocalPackage
  -> [String]
primaryComponentOptions executableBuildStatuses lp =
  -- TODO: get this information from target parsing instead, which will allow
  -- users to turn off library building if desired
     ( if hasBuildableMainLibrary package
         then map T.unpack
           $ T.append "lib:" (T.pack (packageNameString (packageName package)))
           : map
               (T.append "flib:")
               (getBuildableListText (packageForeignLibraries package))
         else []
     )
  ++ map
       (T.unpack . T.append "lib:")
       (getBuildableListText $ packageSubLibraries package)
  ++ map
       (T.unpack . T.append "exe:")
       (Set.toList $ exesToBuild executableBuildStatuses lp)
 where
  package = lpPackage lp

-- | History of this function:
--
-- * Normally it would do either all executables or if the user specified
--   requested components, just build them. Afterwards, due to this Cabal bug
--   <https://github.com/haskell/cabal/issues/2780>, we had to make Stack build
--   all executables every time.
--
-- * In <https://github.com/commercialhaskell/stack/issues/3229> this was
--   flagged up as very undesirable behavior on a large project, hence the
--   behavior below that we build all executables once (modulo success), and
--   thereafter pay attention to user-wanted components.
--
exesToBuild :: Map Text ExecutableBuildStatus -> LocalPackage -> Set Text
exesToBuild executableBuildStatuses lp =
  if cabalIsSatisfied executableBuildStatuses && lpWanted lp
    then exeComponents (lpComponents lp)
    else buildableExes (lpPackage lp)

-- | Do the current executables satisfy Cabal's bugged out requirements?
cabalIsSatisfied :: Map k ExecutableBuildStatus -> Bool
cabalIsSatisfied = all (== ExecutableBuilt) . Map.elems

-- Test-suite and benchmark build components.
finalComponentOptions :: LocalPackage -> [String]
finalComponentOptions lp =
  map (T.unpack . renderComponent) $
  Set.toList $
  Set.filter (\c -> isCTest c || isCBench c) (lpComponents lp)

taskComponents :: Task -> Set NamedComponent
taskComponents task =
  case taskType task of
    TTLocalMutable lp -> lpComponents lp -- FIXME probably just want lpWanted
    TTRemotePackage{} -> Set.empty

expectTestFailure :: PackageName -> Maybe Curator -> Bool
expectTestFailure pname =
  maybe False (Set.member pname . curatorExpectTestFailure)

expectBenchmarkFailure :: PackageName -> Maybe Curator -> Bool
expectBenchmarkFailure pname =
  maybe False (Set.member pname . curatorExpectBenchmarkFailure)

fulfillCuratorBuildExpectations ::
     (HasCallStack, HasTerm env)
  => PackageName
  -> Maybe Curator
  -> Bool
  -> Bool
  -> b
  -> RIO env b
  -> RIO env b
fulfillCuratorBuildExpectations pname mcurator enableTests _ defValue action
  | enableTests && expectTestFailure pname mcurator = do
      eres <- tryAny action
      case eres of
        Right res -> do
          prettyWarnL
            [ style Current (fromPackageName pname) <> ":"
            , flow "unexpected test build success."
            ]
          pure res
        Left _ -> pure defValue
fulfillCuratorBuildExpectations pname mcurator _ enableBench defValue action
  | enableBench && expectBenchmarkFailure pname mcurator = do
      eres <- tryAny action
      case eres of
        Right res -> do
          prettyWarnL
            [ style Current (fromPackageName pname) <> ":"
            , flow "unexpected benchmark build success."
            ]
          pure res
        Left _ -> pure defValue
fulfillCuratorBuildExpectations _ _ _ _ _ action = action
