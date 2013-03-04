module GHCApi where

import CabalApi
import Control.Applicative
import Control.Exception
import CoreMonad
import Data.Maybe (isJust)
import DynFlags
import ErrMsg
import Exception
import GHC
import GHC.Paths (libdir)
import HeaderInfo
import System.Exit
import System.IO
import Types

----------------------------------------------------------------

withGHC :: Alternative m => Ghc (m a) -> IO (m a)
withGHC = withGHC' "Dummy"

withGHC' :: Alternative m => FilePath -> Ghc (m a) -> IO (m a)
withGHC' file body = ghandle ignore $ runGhc (Just libdir) $ do
    dflags <- getSessionDynFlags
    defaultCleanupHandler dflags body
  where
    ignore :: Alternative m => SomeException -> IO (m a)
    ignore e = do
        hPutStr stderr $ file ++ ":0:0:Error:"
        hPrint stderr e
        exitSuccess

----------------------------------------------------------------

initSession0 :: Options -> Ghc [PackageId]
initSession0 opt = do
    dflags0 <- getSessionDynFlags
    dflags1 <- setGhcFlags dflags0 opt
    setSessionDynFlags dflags1

----------------------------------------------------------------

importDirs :: [IncludeDir]
importDirs = [".","..","../..","../../..","../../../..","../../../../.."]

initializeGHC :: Options -> Cradle -> FilePath -> [GHCOption] -> Bool -> Ghc LogReader
initializeGHC opt cradle fileName ghcOptions logging
  | cabal     = do
      (gopts,idirs,depPkgs,hdrExts) <- liftIO $ fromCabalFile ghcOptions cradle
      initSession opt gopts idirs (Just depPkgs) (Just hdrExts) logging fileName
  | otherwise =
      initSession opt ghcOptions importDirs Nothing Nothing logging fileName
  where
    cabal = isJust $ cradleCabalFile cradle

initSession :: Options
            -> [GHCOption]
            -> [IncludeDir]
            -> Maybe [Package]
            -> Maybe [LangExt]
            -> Bool
            -> FilePath
            -> Ghc LogReader
initSession opt cmdOpts idirs mDepPkgs mLangExts logging file = do
    dflags0 <- getSessionDynFlags
    (dflags1,readLog) <- setupDynamicFlags dflags0
    _ <- setSessionDynFlags dflags1
    return readLog
  where
    setupDynamicFlags df0 = do
        df1 <- modifyFlagsWithOpts df0 cmdOpts
        fast <- liftIO $ isFastCheck df0 file mLangExts
        let df2 = modifyFlags df1 idirs mDepPkgs fast (expandSplice opt)
        df3 <- setGhcFlags df2 opt
        liftIO $ setLogger logging df3

----------------------------------------------------------------

getHeaderExtension :: DynFlags -> FilePath -> IO [String]
getHeaderExtension dflags file = map unLoc <$> getOptionsFromFile dflags file

----------------------------------------------------------------

isFastCheck :: DynFlags -> FilePath -> Maybe [LangExt] -> IO Bool
isFastCheck dflags file mLangExts = do
    hdrExts <- getHeaderExtension dflags file
    return . not $ useTemplateHaskell mLangExts hdrExts

useTemplateHaskell :: Maybe [LangExt] -> [HeaderExt] -> Bool
useTemplateHaskell mLangExts hdrExts = th1 || th2
  where
    th1 = "-XTemplateHaskell" `elem` hdrExts
    th2 = maybe False ("TemplateHaskell" `elem`) mLangExts

----------------------------------------------------------------

modifyFlagsWithOpts :: DynFlags -> [String] -> Ghc DynFlags
modifyFlagsWithOpts dflags cmdOpts = do
    (dflags',_,_) <- parseDynamicFlags dflags (map noLoc cmdOpts)
    return dflags'

----------------------------------------------------------------

-- FIXME removing Options
modifyFlags :: DynFlags -> [IncludeDir] -> Maybe [Package] -> Bool -> Bool -> DynFlags
modifyFlags d0 idirs mDepPkgs fast splice
  | splice    = setSplice d3
  | otherwise = d3
  where
    d1 = d0 { importPaths = idirs }
    d2 = setFastOrNot d1 fast
    d3 = maybe d2 (addDevPkgs d2) mDepPkgs

setSplice :: DynFlags -> DynFlags
setSplice dflag = dopt_set dflag Opt_D_dump_splices

setFastOrNot :: DynFlags -> Bool -> DynFlags
setFastOrNot dflags False = dflags {
    ghcLink   = LinkInMemory
  , hscTarget = HscInterpreted
  }
setFastOrNot dflags True = dflags {
    ghcLink   = NoLink
  , hscTarget = HscNothing
  }

addDevPkgs :: DynFlags -> [Package] -> DynFlags
addDevPkgs df pkgs = df''
  where
    df' = dopt_set df Opt_HideAllPackages
    df'' = df' {
        packageFlags = map ExposePackage pkgs ++ packageFlags df
      }

----------------------------------------------------------------

setGhcFlags :: Monad m => DynFlags -> Options -> m DynFlags
setGhcFlags flagset opt =
  do (flagset',_,_) <- parseDynamicFlags flagset (map noLoc (ghcOpts opt))
     return flagset'

----------------------------------------------------------------

setTargetFile :: (GhcMonad m) => String -> m ()
setTargetFile file = do
    target <- guessTarget file Nothing
    setTargets [target]

----------------------------------------------------------------

getDynFlags :: IO DynFlags
getDynFlags = runGhc (Just libdir) getSessionDynFlags
