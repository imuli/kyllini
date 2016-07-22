{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      :  KZC.Flags
-- Copyright   :  (c) 2015-2016 Drexel University
-- License     :  BSD-style
-- Maintainer  :  mainland@cs.drexel.edu

module KZC.Flags (
    ModeFlag(..),
    DynFlag(..),
    WarnFlag(..),
    DumpFlag(..),
    TraceFlag(..),
    Flags(..),

    defaultFlags,

    MonadFlags(..),
    asksFlags,

    flagImplications,

    setMode,

    testDynFlag,
    setDynFlag,
    setDynFlags,
    unsetDynFlag,

    testWarnFlag,
    setWarnFlag,
    setWarnFlags,
    unsetWarnFlag,

    testWerrorFlag,
    setWerrorFlag,
    setWerrorFlags,
    unsetWerrorFlag,

    testDumpFlag,
    setDumpFlag,
    setDumpFlags,

    testTraceFlag,
    setTraceFlag,
    setTraceFlags,

    whenDynFlag,
    whenWarnFlag,
    whenWerrorFlag,
    whenDumpFlag,
    whenVerb,
    whenVerbLevel
  ) where

import Control.Monad (when)
#if !MIN_VERSION_base(4,8,0)
import Control.Monad.Error (Error, ErrorT(..))
#endif /* !MIN_VERSION_base(4,8,0) */
import Control.Monad.Except (ExceptT(..), runExceptT)
import Control.Monad.Exception (ExceptionT(..), runExceptionT)
import Control.Monad.Reader (ReaderT(..))
import Control.Monad.State (StateT(..))
import qualified Control.Monad.State.Strict as S (StateT(..))
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Cont (ContT(..))
import qualified Control.Monad.Trans.Cont as Cont
import Control.Monad.Trans.Maybe (MaybeT(..))
import Control.Monad.Writer (WriterT(..))
import qualified Control.Monad.Writer.Strict as S (WriterT(..))
import Data.Bits
import Data.List (foldl')
import Data.Monoid
import Data.Word

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
             | Fuse
             | Simplify
             | MayInlineVal
             | MayInlineFun
             | MayInlineComp
             | AlwaysInlineComp
             | BoundsCheck
             | PartialEval
             | Timers
             | AutoLUT
             | LUT
             | NoGensym
             | Pipeline
             | Coalesce
             | VectOnlyBytes
             | VectFilterAnn
             | CoalesceTop
             | FuseUnroll
             | ShowCgStats
             | ShowFusionStats
  deriving (Eq, Ord, Enum, Bounded, Show)

data WarnFlag = WarnSimplifierBailout
              | WarnUnusedCommandBind
              | WarnUnsafeAutoCast
              | WarnUnsafeParAutoCast
              | WarnRateMismatch
              | WarnFusionFailure
  deriving (Eq, Ord, Enum, Bounded, Show)

data DumpFlag = DumpCPP
              | DumpRename
              | DumpLift
              | DumpFusion
              | DumpCore
              | DumpOcc
              | DumpSimpl
              | DumpEval
              | DumpAutoLUT
              | DumpLUT
              | DumpHashCons
              | DumpStaticRefs
              | DumpRate
              | DumpCoalesce
  deriving (Eq, Ord, Enum, Bounded, Show)

data TraceFlag = TracePhase
               | TraceLexer
               | TraceParser
               | TraceRn
               | TraceLift
               | TraceTc
               | TraceCg
               | TraceLint
               | TraceExprToCore
               | TraceFusion
               | TraceSimplify
               | TraceEval
               | TraceAutoLUT
               | TraceLUT
               | TraceRefFlow
               | TraceNeedDefault
               | TraceRate
               | TraceCoalesce
  deriving (Eq, Ord, Enum, Bounded, Show)

newtype FlagSet a = FlagSet Word32
  deriving (Eq, Ord)

testFlag :: Enum a => FlagSet a -> a -> Bool
testFlag (FlagSet fs) f = fs `testBit` fromEnum f

setFlag :: Enum a => FlagSet a -> a -> FlagSet a
setFlag (FlagSet fs) f = FlagSet $ fs `setBit` fromEnum f

unsetFlag :: Enum a => FlagSet a -> a -> FlagSet a
unsetFlag (FlagSet fs) f = FlagSet $ fs `clearBit` fromEnum f

instance Monoid (FlagSet a) where
    mempty = FlagSet 0

    FlagSet x `mappend` FlagSet y = FlagSet (x .|. y)

instance (Enum a, Bounded a, Show a) => Show (FlagSet a) where
    show (FlagSet n) = show [f | f <- [minBound..maxBound::a],
                                 n `testBit` fromEnum f]

data Flags = Flags
    { mode       :: !ModeFlag
    , verbLevel  :: !Int
    , maxErrCtx  :: !Int
    , maxSimpl   :: !Int
    , maxLUT     :: !Int
    , maxLUTLog2 :: !Int
    , minLUTOps  :: !Int

    , maxFusionBlowup :: !Double

    , dynFlags    :: !(FlagSet DynFlag)
    , warnFlags   :: !(FlagSet WarnFlag)
    , werrorFlags :: !(FlagSet WarnFlag)
    , dumpFlags   :: !(FlagSet DumpFlag)
    , traceFlags  :: !(FlagSet TraceFlag)

    , includePaths :: ![FilePath]
    , defines      :: ![(String, String)]

    , output  :: Maybe FilePath
    , dumpDir :: Maybe FilePath
    }
  deriving (Eq, Ord, Show)

instance Monoid Flags where
    mempty = Flags
        { mode       = Compile
        , verbLevel  = 0
        , maxErrCtx  = 1
        , maxSimpl   = 10
        , maxLUT     = 256*1024 -- Default maximum size for LUT is 256K bytes
        , maxLUTLog2 = 8 + 10  -- Default maximum size for LUT log_2 is 18
        , minLUTOps  = 5 -- Minimum number of operations necessary to consider a
                         -- LUT for an expression

        -- Maximum ratio of new code size to old code size. Why 3? Because
        -- transforming an expression to work over segments of an array requires
        -- a multiply and add for each index operation, which adds 2 operations,
        -- meaning overall we get approximately 3x the number of original
        -- operations.
        , maxFusionBlowup = 3.0

        , dynFlags    = mempty
        , werrorFlags = mempty
        , warnFlags   = mempty
        , dumpFlags   = mempty
        , traceFlags  = mempty

        , includePaths = []
        , defines      = []

        , output  = Nothing
        , dumpDir = Nothing
        }

    mappend f1 f2 = Flags
        { mode       = mode f2
        , verbLevel  = verbLevel f1 + verbLevel f2
        , maxErrCtx  = max (maxErrCtx f1) (maxErrCtx f2)
        , maxSimpl   = max (maxSimpl f1) (maxSimpl f2)
        , maxLUT     = max (maxLUT f1) (maxLUT f2)
        , maxLUTLog2 = max (maxLUT f1) (maxLUT f2)
        , minLUTOps  = min (minLUTOps f1) (minLUTOps f2)

        , maxFusionBlowup = max (maxFusionBlowup f1) (maxFusionBlowup f2)

        , dynFlags    = dynFlags f1    <> dynFlags f2
        , warnFlags   = warnFlags f1   <> warnFlags f2
        , werrorFlags = werrorFlags f1 <> werrorFlags f2
        , dumpFlags   = dumpFlags f1   <> dumpFlags f2
        , traceFlags  = traceFlags f1  <> traceFlags f2

        , includePaths = includePaths f1 <> includePaths f2
        , defines      = defines f1 <> defines f2

        , output  = output  f1 <> output f2
        , dumpDir = dumpDir f1 <> dumpDir f2
        }

defaultFlags :: Flags
defaultFlags =
    setFlags setDynFlag  defaultDynFlags $
    setFlags setWarnFlag defaultWarnFlags
    mempty
  where
    setFlags :: (a -> Flags -> Flags)
             -> [a]
             -> Flags
             -> Flags
    setFlags f xs flags = foldl' (flip f) flags xs

    defaultDynFlags :: [DynFlag]
    defaultDynFlags = [ LinePragmas
                      , VectFilterAnn]

    defaultWarnFlags :: [WarnFlag]
    defaultWarnFlags = [ WarnSimplifierBailout
                       , WarnUnusedCommandBind
                       , WarnUnsafeAutoCast
                       ]

class Monad m => MonadFlags m where
    askFlags   :: m Flags
    localFlags :: (Flags -> Flags) -> m a -> m a

asksFlags :: MonadFlags m => (Flags -> a) -> m a
asksFlags f = fmap f askFlags

-- | Set all flags implied by other flags
flagImplications :: Flags -> Flags
flagImplications = fixpoint go
  where
    fixpoint :: Eq a => (a -> a) -> a -> a
    fixpoint f x | x' == x   = x
                 | otherwise = fixpoint f x'
      where
        x' = f x

    go :: Flags -> Flags
    go = imp Fuse (setDynFlag AlwaysInlineComp) .
         imp Coalesce (setDynFlag AlwaysInlineComp) .
         imp MayInlineVal (setDynFlag Simplify) .
         imp MayInlineFun (setDynFlag Simplify) .
         imp MayInlineComp (setDynFlag Simplify) .
         imp AlwaysInlineComp (setDynFlag Simplify)

    imp :: DynFlag
        -> (Flags -> Flags)
        -> Flags -> Flags
    imp f g fs =
        if testDynFlag f fs then g fs else fs

instance MonadFlags m => MonadFlags (MaybeT m) where
    askFlags       = lift askFlags
    localFlags f m = MaybeT $ localFlags f (runMaybeT m)

instance MonadFlags m => MonadFlags (ContT r m) where
    askFlags   = lift askFlags
    localFlags = Cont.liftLocal askFlags localFlags

#if !MIN_VERSION_base(4,8,0)
instance (Error e, MonadFlags m) => MonadFlags (ErrorT e m) where
    askFlags       = lift askFlags
    localFlags f m = ErrorT $ localFlags f (runErrorT m)
#endif /* !MIN_VERSION_base(4,8,0) */

instance (MonadFlags m) => MonadFlags (ExceptT e m) where
    askFlags       = lift askFlags
    localFlags f m = ExceptT $ localFlags f (runExceptT m)

instance (MonadFlags m) => MonadFlags (ExceptionT m) where
    askFlags       = lift askFlags
    localFlags f m = ExceptionT $ localFlags f (runExceptionT m)

instance MonadFlags m => MonadFlags (ReaderT r m) where
    askFlags       = lift askFlags
    localFlags f m = ReaderT $ \r -> localFlags f (runReaderT m r)

instance MonadFlags m => MonadFlags (StateT s m) where
    askFlags       = lift askFlags
    localFlags f m = StateT $ \s -> localFlags f (runStateT m s)

instance MonadFlags m => MonadFlags (S.StateT s m) where
    askFlags       = lift askFlags
    localFlags f m = S.StateT $ \s -> localFlags f (S.runStateT m s)

instance (Monoid w, MonadFlags m) => MonadFlags (WriterT w m) where
    askFlags       = lift askFlags
    localFlags f m = WriterT $ localFlags f (runWriterT m)

instance (Monoid w, MonadFlags m) => MonadFlags (S.WriterT w m) where
    askFlags       = lift askFlags
    localFlags f m = S.WriterT $ localFlags f (S.runWriterT m)

setMode :: ModeFlag -> Flags -> Flags
setMode f flags = flags { mode = f }

testDynFlag :: DynFlag -> Flags -> Bool
testDynFlag f flags = dynFlags flags `testFlag` f

setDynFlag :: DynFlag -> Flags -> Flags
setDynFlag f flags = flags { dynFlags = setFlag (dynFlags flags) f }

setDynFlags :: [DynFlag] -> Flags -> Flags
setDynFlags fs flags = foldl' (flip setDynFlag) flags fs

unsetDynFlag :: DynFlag -> Flags -> Flags
unsetDynFlag f flags = flags { dynFlags = unsetFlag (dynFlags flags) f }

testWarnFlag :: WarnFlag -> Flags -> Bool
testWarnFlag f flags = warnFlags flags `testFlag` f

setWarnFlag :: WarnFlag -> Flags -> Flags
setWarnFlag f flags = flags { warnFlags = setFlag (warnFlags flags) f }

setWarnFlags :: [WarnFlag] -> Flags -> Flags
setWarnFlags fs flags = foldl' (flip setWarnFlag) flags fs

unsetWarnFlag :: WarnFlag -> Flags -> Flags
unsetWarnFlag f flags = flags { warnFlags = unsetFlag (warnFlags flags) f }

testWerrorFlag :: WarnFlag -> Flags -> Bool
testWerrorFlag f flags = werrorFlags flags `testFlag` f

setWerrorFlag :: WarnFlag -> Flags -> Flags
setWerrorFlag f flags = flags { werrorFlags = setFlag (werrorFlags flags) f }

setWerrorFlags :: [WarnFlag] -> Flags -> Flags
setWerrorFlags fs flags = foldl' (flip setWerrorFlag) flags fs

unsetWerrorFlag :: WarnFlag -> Flags -> Flags
unsetWerrorFlag f flags = flags { werrorFlags = unsetFlag (werrorFlags flags) f }

testDumpFlag :: DumpFlag -> Flags -> Bool
testDumpFlag f flags = dumpFlags flags `testFlag` f

setDumpFlag :: DumpFlag -> Flags -> Flags
setDumpFlag f flags = flags { dumpFlags = setFlag (dumpFlags flags) f }

setDumpFlags :: [DumpFlag] -> Flags -> Flags
setDumpFlags fs flags = foldl' (flip setDumpFlag) flags fs

testTraceFlag :: TraceFlag -> Flags -> Bool
testTraceFlag f flags = traceFlags flags `testFlag` f

setTraceFlag :: TraceFlag -> Flags -> Flags
setTraceFlag f flags = flags { traceFlags = setFlag (traceFlags flags) f }

setTraceFlags :: [TraceFlag] -> Flags -> Flags
setTraceFlags fs flags = foldl' (flip setTraceFlag) flags fs

whenDynFlag :: MonadFlags m => DynFlag -> m () -> m ()
whenDynFlag f act = do
    doDump <- asksFlags (testDynFlag f)
    when doDump act

whenWarnFlag :: MonadFlags m => WarnFlag -> m () -> m ()
whenWarnFlag f act = do
    doDump <- asksFlags (testWarnFlag f)
    when doDump act

whenWerrorFlag :: MonadFlags m => WarnFlag -> m () -> m ()
whenWerrorFlag f act = do
    doDump <- asksFlags (testWerrorFlag f)
    when doDump act

whenDumpFlag :: MonadFlags m => DumpFlag -> m () -> m ()
whenDumpFlag f act = do
    doDump <- asksFlags (testDumpFlag f)
    when doDump act

whenVerb :: MonadFlags m => m () -> m ()
whenVerb = whenVerbLevel 1

whenVerbLevel :: MonadFlags m => Int -> m () -> m ()
whenVerbLevel lvlNeeded act = do
    lvl <- asksFlags verbLevel
    when (lvl >= lvlNeeded) act
