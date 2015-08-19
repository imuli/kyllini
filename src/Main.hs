module Main where

import Control.Applicative
import Control.Monad.Exception
import Control.Monad.IO.Class
import Control.Monad.Reader
import qualified Data.ByteString.Lazy as B
import Data.Loc
import qualified Data.Text.Lazy.IO as TIO
import qualified Data.Text.Lazy.Encoding as E
import System.Directory (createDirectoryIfMissing)
import System.Environment
import System.Exit (exitFailure)
import System.FilePath (addExtension,
                        replaceExtension,
                        splitExtension,
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
import KZC.Flags
import qualified KZC.Lint as Lint
import KZC.Monad
import KZC.Rename
import KZC.SysTools

import Opts

main :: IO ()
main = do
    args <- getArgs
    (fs, files) <- compilerOpts args
    if mode fs == Help
      then do usage >>= hPutStrLn stderr
              return ()
      else evalKZC fs (mapM_ runPipeline files) `catch` printFailure
  where
    printFailure :: SomeException -> IO ()
    printFailure e = (hPutStrLn stderr . show) e >> exitFailure

runPipeline :: FilePath -> KZC ()
runPipeline filepath = do
    text  <- liftIO (E.decodeUtf8 <$> B.readFile filepath)
    text' <- runCpp filepath text
    whenDumpFlag DumpCPP $ do
        liftIO $ TIO.writeFile (addExtension root (".pp" ++ ext)) text'
    decls <- liftIO $ parseProgram text' start
    whenDynFlag PrettyPrint $
      liftIO $ putDocLn $ ppr decls
    whenDynFlag Check $
      void $ pipeline decls
  where
    (root, ext) = splitExtension filepath

    start :: Pos
    start = startPos filepath

    pipeline :: [Z.CompLet] -> KZC C.Exp
    pipeline = renamePipe >=> checkPipe

    renamePipe :: [Z.CompLet] -> KZC [Z.CompLet]
    renamePipe = runRn . renameProgram >=> dumpPass DumpRename "z" "rn"

    checkPipe :: [Z.CompLet] -> KZC C.Exp
    checkPipe = withTi . checkProgram >=> dumpPass DumpCore "core" "tc" >=> lintCore

    lintCore :: C.Exp -> KZC C.Exp
    lintCore e = do
        whenDynFlag Lint $
            Lint.withTc $ void $ Lint.inferExp e
        return e

{-
    flagPass :: (Flags -> Bool) -> (a -> KZC a) -> a -> KZC a
    flagPass f k a = do
        dopass <- asks (f . flags)
        if dopass then k a else return a
-}

    dumpPass :: Pretty a
             => DumpFlag
             -> String
             -> String
             -> a
             -> KZC a
    dumpPass f ext suffix x = do
        dump f filepath ext suffix (ppr x)
        return x

    dump :: DumpFlag
         -> FilePath
         -> String
         -> String
         -> Doc
         -> KZC ()
    dump f sourcePath ext suffix doc = whenDumpFlag f $ do
        let destpath = replaceExtension sourcePath ext'
        liftIO $ createDirectoryIfMissing True (takeDirectory destpath)
        h <- liftIO $ openFile destpath WriteMode
        liftIO $ B.hPut h $ E.encodeUtf8 (prettyLazyText 80 doc)
        liftIO $ hClose h
      where
        ext' :: String
        ext' | null suffix = "dump" ++ "." ++ ext
             | otherwise   = "dump"  ++ "-" ++ suffix ++ "." ++ ext
