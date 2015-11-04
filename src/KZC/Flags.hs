-- |
-- Module      :  KZC.Flags
-- Copyright   :  (c) 2015 Drexel University
-- License     :  BSD-style
-- Maintainer  :  mainland@cs.drexel.edu

module KZC.Flags (
    ModeFlag(..),
    DynFlag(..),
    WarnFlag(..),
    DumpFlag(..),
    TraceFlag(..),
    Flags(..),

    MonadFlags(..),
    asksFlags,

    setMode,
    testDynFlag,
    setDynFlag,
    unsetDynFlag,
    testWarnFlag,
    setWarnFlag,
    unsetWarnFlag,
    testDumpFlag,
    setDumpFlag,
    testTraceFlag,
    setTraceFlag,

    whenDynFlag,
    whenWarnFlag,
    whenDumpFlag
  ) where

import Control.Monad (liftM,
                      when)
import Control.Monad.Reader (ReaderT(..))
import Control.Monad.State (StateT(..))
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Maybe (MaybeT(..))
import Data.Bits
import Data.Int
import Data.Monoid

data ModeFlag = Help
              | Compile
  deriving (Eq, Ord, Enum, Show)

data DynFlag = Quiet
             | StopAfterParse
             | StopAfterCheck
             | PrettyPrint
             | Lint
             | PrintUniques
             | ExpertTypes
             | LinePragmas
             | Auto
             | Flatten
             | AutoLint
  deriving (Eq, Ord, Enum, Show)

data WarnFlag = WarnError
  deriving (Eq, Ord, Enum, Show)

data DumpFlag = DumpCPP
              | DumpRename
              | DumpLift
              | DumpFlatten
              | DumpCore
              | DumpAuto
  deriving (Eq, Ord, Enum, Show)

data TraceFlag = TraceLexer
               | TraceParser
               | TraceRn
               | TraceLift
               | TraceTc
               | TraceCg
               | TraceLint
               | TraceAuto
               | TraceAutoLint
               | TraceFlatten
  deriving (Eq, Ord, Enum, Show)

data Flags = Flags
    { mode      :: !ModeFlag
    , verbLevel :: !Int

    , dynFlags   :: !Int32
    , warnFlags  :: !Int32
    , dumpFlags  :: !Int32
    , traceFlags :: !Int32

    , includePaths :: ![FilePath]
    , defines      :: ![(String, String)]

    , output  :: Maybe FilePath
    , dumpDir :: Maybe FilePath
    }
  deriving (Eq, Ord, Show)

instance Monoid Flags where
    mempty = Flags
        { mode      = Compile
        , verbLevel = 0

        , dynFlags   = bit (fromEnum LinePragmas)
        , warnFlags  = 0
        , dumpFlags  = 0
        , traceFlags = 0

        , includePaths = []
        , defines      = []

        , output  = Nothing
        , dumpDir = Nothing
        }

    mappend f1 f2 = Flags
        { mode      = mode f2
        , verbLevel = verbLevel f1 + verbLevel f2

        , dynFlags   = dynFlags f1   .|. dynFlags f2
        , warnFlags  = warnFlags f1  .|. warnFlags f2
        , dumpFlags  = dumpFlags f1  .|. dumpFlags f2
        , traceFlags = traceFlags f1 .|. traceFlags f2

        , includePaths = includePaths f1 <> includePaths f2
        , defines      = defines f1 <> defines f2

        , output  = output  f1 <> output f2
        , dumpDir = dumpDir f1 <> dumpDir f2
        }

class Monad m => MonadFlags m where
    askFlags   :: m Flags
    localFlags :: Flags -> m a -> m a

asksFlags :: MonadFlags m => (Flags -> a) -> m a
asksFlags f = liftM f askFlags

instance MonadFlags m => MonadFlags (MaybeT m) where
    askFlags        = lift askFlags
    localFlags fs m = MaybeT $ localFlags fs (runMaybeT m)

instance MonadFlags m => MonadFlags (ReaderT r m) where
    askFlags        = lift askFlags
    localFlags fs m = ReaderT $ \r -> localFlags fs (runReaderT m r)

instance MonadFlags m => MonadFlags (StateT s m) where
    askFlags        = lift askFlags
    localFlags fs m = StateT $ \s -> localFlags fs (runStateT m s)

setMode :: ModeFlag -> Flags -> Flags
setMode f flags = flags { mode = f }

testDynFlag :: DynFlag -> Flags -> Bool
testDynFlag f flags =
    dynFlags flags `testBit` fromEnum f

setDynFlag :: DynFlag -> Flags -> Flags
setDynFlag f flags =
    flags { dynFlags = dynFlags flags `setBit` fromEnum f }

unsetDynFlag :: DynFlag -> Flags -> Flags
unsetDynFlag f flags =
    flags { dynFlags = dynFlags flags `clearBit` fromEnum f }

testWarnFlag :: WarnFlag -> Flags -> Bool
testWarnFlag f flags =
    warnFlags flags `testBit` fromEnum f

setWarnFlag :: WarnFlag -> Flags -> Flags
setWarnFlag f flags =
    flags { warnFlags = warnFlags flags `setBit` fromEnum f }

unsetWarnFlag :: WarnFlag -> Flags -> Flags
unsetWarnFlag f flags =
    flags { warnFlags = warnFlags flags `clearBit` fromEnum f }

testDumpFlag :: DumpFlag -> Flags -> Bool
testDumpFlag f flags =
    dumpFlags flags `testBit` fromEnum f

setDumpFlag :: DumpFlag -> Flags -> Flags
setDumpFlag f flags =
    flags { dumpFlags = dumpFlags flags `setBit` fromEnum f }

testTraceFlag :: TraceFlag -> Flags -> Bool
testTraceFlag f flags =
    traceFlags flags `testBit` fromEnum f

setTraceFlag :: TraceFlag -> Flags -> Flags
setTraceFlag f flags =
    flags { traceFlags = traceFlags flags `setBit` fromEnum f }

whenDynFlag :: MonadFlags m => DynFlag -> m () -> m ()
whenDynFlag f act = do
    doDump <- asksFlags (testDynFlag f)
    when doDump act

whenWarnFlag :: MonadFlags m => WarnFlag -> m () -> m ()
whenWarnFlag f act = do
    doDump <- asksFlags (testWarnFlag f)
    when doDump act

whenDumpFlag :: MonadFlags m => DumpFlag -> m () -> m ()
whenDumpFlag f act = do
    doDump <- asksFlags (testDumpFlag f)
    when doDump act
