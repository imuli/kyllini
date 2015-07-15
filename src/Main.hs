module Main where

import Control.Monad.Exception
import Control.Monad.IO.Class
import Control.Monad.Reader
import qualified Data.ByteString.Lazy as B
import qualified Data.Text.Lazy.Encoding as E
import System.Directory (createDirectoryIfMissing)
import System.Environment
import System.Exit (exitFailure)
import System.FilePath (replaceExtension,
                        takeDirectory)
import System.IO (IOMode(..),
                  hClose,
                  hPutStrLn,
                  openFile,
                  stderr)

import qualified Language.Core.Syntax as C
import Language.Ziria.Parser
import qualified Language.Ziria.Syntax as Z
import Text.PrettyPrint.Mainland

import KZC.Check
import KZC.Check.Monad
import KZC.Flags
import KZC.Monad

import Opts

main :: IO ()
main = do
    args <- getArgs
    (flags, files) <- compilerOpts args
    evalKZC flags (mapM_ runPipeline files) `catch` printFailure
  where
    printFailure :: SomeException -> IO ()
    printFailure e = (hPutStrLn stderr . show) e >> exitFailure

runPipeline :: FilePath -> KZC ()
runPipeline path0 = do
    decls <- liftIO $ parseProgramFromFile path0
    whenFlag checkF $
      void $ pipeline decls
  where
    pipeline :: [Z.CompLet] -> KZC C.Exp
    pipeline = checkPipeline

    checkPipeline :: [Z.CompLet] -> KZC C.Exp
    checkPipeline = check >=> dumpPass dumpTcF "core" "tc" >=> lintCore

    check :: [Z.CompLet] -> KZC C.Exp
    check decls = withTc $ checkProgram decls

    lintCore :: C.Exp -> KZC C.Exp
    lintCore e = do
{-
        whenFlag lintf $
            liftLintCont $ lintDecls cdecls
-}
        return e

    whenFlag :: (Flags -> Bool) -> KZC () -> KZC ()
    whenFlag f m = do
        dopass <- asks (f . flags)
        if dopass then m else return ()

{-
    flagPass :: (Flags -> Bool) -> (a -> KZC a) -> a -> KZC a
    flagPass f k a = do
        dopass <- asks (f . flags)
        if dopass then k a else return a
-}

    dumpPass :: Pretty a
             => (Flags -> Bool)
             -> String
             -> String
             -> a
             -> KZC a
    dumpPass f ext suffix x = do
        dump f path0 ext suffix (ppr x)
        return x

    dump :: (Flags -> Bool)
         -> FilePath
         -> String
         -> String
         -> Doc
         -> KZC ()
    dump f sourcePath ext suffix doc = whenFlag f $ do
        let path = replaceExtension sourcePath ext'
        liftIO $ createDirectoryIfMissing True (takeDirectory path)
        h <- liftIO $ openFile path WriteMode
        liftIO $ B.hPut h $ E.encodeUtf8 (prettyLazyText 80 doc)
        liftIO $ hClose h
      where
        ext' :: String
        ext' | null suffix = "dump" ++ "." ++ ext
             | otherwise   = "dump"  ++ "-" ++ suffix ++ "." ++ ext
