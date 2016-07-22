{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances#-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      :  KZC.Interp
-- Copyright   :  (c) 2016 Drexel University
-- License     :  BSD-style
-- Maintainer  :  mainland@cs.drexel.edu

module KZC.Interp (
    I,
    evalI,

    Val,
    fromConst,
    toConst,
    defaultVal,

    enumVals,
    enumValsList,

    Ref,
    fromRef,
    toRef,
    defaultRef,
    idxR,

    lookupVal,
    extendVals,

    lookupRef,
    extendRefs,

    assign,

    evalExp,

    compileExp
  ) where

import Control.Monad (void)
import Control.Monad.Exception (MonadException(..))
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Primitive (PrimMonad(..),
                                RealWorld)
import Control.Monad.Reader (MonadReader(..),
                             ReaderT(..),
                             asks)
import Control.Monad.Ref (MonadRef(..))
import Control.Monad.Trans.Class (MonadTrans(..))
import Data.Binary.IEEE754 (wordToFloat,
                            wordToDouble)
import Data.Bits
import Data.IORef (IORef)
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Vector as V
import Data.Vector.Mutable (MVector)
import qualified Data.Vector.Mutable as MV
import Data.Word (Word32,
                  Word64)
import GHC.Float (float2Double)
import Text.PrettyPrint.Mainland

import KZC.Core.Enum
import KZC.Core.Lint
import KZC.Core.Smart
import KZC.Core.Syntax hiding (I)
import qualified KZC.Core.Syntax as S
import KZC.Error
import KZC.Flags
import KZC.Trace
import KZC.Uniq
import KZC.Util.Env

-- | Values.
type Val = Const

isBaseV :: Val -> Bool
isBaseV StructC{} = False
isBaseV ArrayC{}  = False
isBaseV _         = True

-- | Convert a constant to a value
fromConst :: Const -> Val
fromConst = id

-- | Convert a value to a constant
toConst :: Val -> Const
toConst = id

-- | Produce a default value of the given type.
defaultVal :: MonadTcRef m => Type -> m Val
defaultVal tau = fromConst <$> defaultValueC tau

-- | Convert an 'Integral' value to a 'Val' of the given (fixpoint) type.
intV :: Integral i => Type -> i -> Val
intV ~(FixT sc s w bp _) i =
    FixC sc s w bp (fromIntegral i)

-- | Convert a 'Val' to an 'Integral' value.
fromIntV :: (Integral a, Monad m) => Val -> m a
fromIntV (FixC S.I _ _ 0 x) =
    return $ fromIntegral x

fromIntV val =
    faildoc $ text "Not an integer:" <+> ppr val

idxV :: Monad m => Val -> Int -> Maybe Int -> m Val
idxV (ArrayC v) i Nothing =
    maybe err return $ v V.!? i
  where
    err = faildoc $ text "Array access out of bounds"

idxV (ArrayC v) i (Just len) =
    return $ ArrayC $ V.slice i len v

idxV val _ _ =
    faildoc $ text "Cannot index into non-array:" <+> ppr val

projV :: Monad m => Val -> Field -> m Val
projV (StructC _ flds) f =
    maybe err return $ lookup f flds
  where
    err = faildoc $ text "Unknown struct field" <+> ppr f

projV val _ =
  faildoc $ text "Cannot project from non-struct:" <+> ppr val

-- | Enumerate all values of a type /in bit order/.
enumVals :: MonadTc m
         => Type
         -> m [Val]
enumVals UnitT{} =
    return [UnitC]

enumVals BoolT{} =
    return $ map BoolC [(minBound :: Bool)..]

enumVals (FixT S.I U (W w) (BP 0) _) =
    return $ map (FixC S.I U (W w) (BP 0))
                 [0..hi]
  where
    hi :: Int
    hi = 2^w-1

enumVals (FixT S.I S (W w) (BP 0) _) =
    return $ map (FixC S.I S (W w) (BP 0)) $
                 [0..hi] ++ [lo..0]
  where
    hi, lo :: Int
    hi = 2^(w-1)-1
    lo = -(2^(w-1))

enumVals (FloatT FP32 _) =
    return $ map (FloatC FP32 . float2Double . wordToFloat)
                 [(minBound :: Word32)..]

enumVals (FloatT FP64 _) =
    return $ map (FloatC FP64 . wordToDouble)
                 [(minBound :: Word64)..]

enumVals (RefT tau _) =
    enumVals tau

enumVals (StructT sname _) = do
    StructDef _ flds _ <- lookupStruct sname
    let fs :: [Field]
        taus :: [Type]
        (fs, taus) = unzip flds
    valss <- enumValsList taus
    return [StructC sname (fs `zip` vals) | vals <- valss]

enumVals (ArrT (ConstI n _) tau _) = do
    valss <- enumValsList (replicate n tau)
    return [ArrayC (V.fromList vals) | vals <- valss]

enumVals tau =
    faildoc $ text "Cannot enumerate values of type" <+> ppr tau

enumValsList :: MonadTc m
             => [Type]
             -> m [[Val]]
enumValsList [] =
    return []

enumValsList [tau] = do
    vals <- enumVals tau
    return [[val] | val <- vals]

enumValsList (tau:taus) = do
    vals  <- enumVals tau
    valss <- enumValsList taus
    return [val':vals' | vals' <- valss, val' <- vals]

-- | References
data Ref s -- | A reference to a value
           = ValR !(IORef Val)
           -- | A struct reference
           | StructR Struct ![(Field, Ref s)]
           -- | A reference to an array of values of base type
           | ArrayR !(MVector s Val)
           -- | A reference to an element of base type in a mutable array.
           | IdxR !(MVector s Val) !Int
           -- | A nested array of references
           | ArrayRefR !(MVector s (Ref s))

instance Pretty (Ref s) where
    ppr ValR{}      = text "<mutable value>"
    ppr StructR{}   = text "<mutable struct>"
    ppr ArrayR{}    = text "<mutable array>"
    ppr IdxR{}      = text "<mutable array element>"
    ppr ArrayRefR{} = text "<mutable array of references>"

-- | Convert a reference to a value.
fromRef :: (PrimMonad m, MonadRef IORef m) => Ref (PrimState m) -> m Val
fromRef (ValR ref) =
    readRef ref

fromRef (StructR struct flds) =
    StructC struct <$> (zip fs <$> mapM fromRef rs)
  where
    (fs, rs) = unzip flds

fromRef (ArrayR mv) =
    ArrayC <$> V.freeze mv

fromRef (IdxR mv i) =
    MV.read mv i

fromRef (ArrayRefR mv) =
    ArrayC <$> (V.freeze mv >>= V.mapM fromRef)

toRef :: (PrimMonad m, MonadRef IORef m) => Val -> m (Ref (PrimState m))
toRef (ArrayC vs) | isBaseV (V.head vs) =
    ArrayR <$> V.thaw vs

toRef (ArrayC vs) =
    ArrayRefR <$> (V.mapM toRef vs >>= V.thaw)

toRef (StructC struct flds) =
    StructR struct <$> (zip fs <$> mapM toRef cs)
  where
    (fs, cs) = unzip flds

toRef val =
    ValR <$> newRef val

-- | Produce a default referec of the given type.
defaultRef :: MonadTcRef m => Type -> m (Ref (PrimState m))
defaultRef (RefT tau _) =
    defaultRef tau

defaultRef (StructT struct _) = do
    StructDef _ flds _ <- lookupStruct struct
    let (fs, taus)     =  unzip flds
    refs               <- mapM defaultRef taus
    return $ StructR struct (fs `zip` refs)

defaultRef (ArrT (ConstI n _) tau _) | isBaseT tau = do
    val <- defaultVal tau
    ArrayR <$> MV.replicate n val

defaultRef (ArrT (ConstI n _) tau _) =
    ArrayRefR <$> (V.replicateM n (defaultRef tau) >>= V.thaw)

defaultRef tau =
    ValR <$> (defaultVal tau >>= newRef)

idxR :: (PrimMonad m, MonadRef IORef m)
     => Ref (PrimState m)
     -> Int
     -> Maybe Int
     -> m (Ref (PrimState m))
idxR (ArrayR mv) i Nothing =
    return $ IdxR mv i

idxR (ArrayRefR mv) i Nothing =
    MV.read mv i

idxR (ArrayR mv) i (Just len) =
    return $ ArrayR $ MV.slice i len mv

idxR (ArrayRefR mv) i (Just len) =
    return $ ArrayRefR $ MV.slice i len mv

idxR val _ _ =
    faildoc $ text "Cannot index into non-array:" <+> ppr val

projR :: (PrimMonad m, MonadRef IORef m)
      => Ref (PrimState m)
      -> Field
      -> m (Ref (PrimState m))
projR (StructR _ flds) f =
    maybe err return $ lookup f flds
  where
    err = faildoc $ text "Unknown struct field" <+> ppr f

projR val _ =
    faildoc $ text "Cannot project from non-struct:" <+> ppr val

-- | The environment for the 'I' monad.
data IEnv s = IEnv { refs :: !(Map Var (Ref s)) }

defaultIEnv :: IEnv s
defaultIEnv = IEnv { refs = mempty }

newtype I s m a = I { unI :: ReaderT (IEnv s) m a }
  deriving (Applicative, Functor, Monad, MonadIO,
            MonadReader (IEnv s),
            MonadException,
            MonadUnique,
            MonadErr,
            MonadFlags,
            MonadTrace,
            MonadTc)

deriving instance MonadRef IORef m => MonadRef IORef (I s m)

instance PrimMonad m => PrimMonad (I s m) where
  type PrimState (I s m) = PrimState m
  primitive = I . primitive

instance MonadTrans (I s) where
  lift m = I $ lift m

instance MonadTcRef m => MonadTcRef (I s m) where

evalI :: MonadTcRef m => I s m a -> m a
evalI m = runReaderT (unI m) defaultIEnv

lookupVal :: (s ~ PrimState m, MonadTcRef m) => Var -> I s m Val
lookupVal v = lookupRef v >>= fromRef

extendVals :: (s ~ PrimState m, MonadTcRef m)
           => [(Var, Val)]
           -> I s m a
           -> I s m a
extendVals vbs m = do
    refs <- mapM toRef vals
    extendRefs (vs `zip` refs) m
  where
    (vs, vals) = unzip vbs

lookupRef :: MonadTcRef m => Var -> I s m (Ref s)
lookupRef v = do
    maybe_ref <- asks (Map.lookup v . refs)
    case maybe_ref of
        Nothing  -> faildoc $ text "Variable" <+> ppr v <+> text "not in scope."
        Just ref -> return ref

extendRefs :: MonadTcRef m => [(Var, Ref s)] -> I s m a -> I s m a
extendRefs = extendEnv refs (\env x -> env { refs = x })

assign :: forall s m . (s ~ PrimState m, PrimMonad m, MonadRef IORef m)
       => Ref s -> Val -> m ()
assign (ValR ref) val =
    val `seq` writeRef ref val

assign (StructR _ flds) (StructC _ flds') =
    mapM_ (assignField flds') flds
  where
    assignField :: [(Field, Val)] -> (Field, Ref s) -> m ()
    assignField flds' (f, old) = do
        new <- maybe err return $ lookup f flds'
        new `seq` assign old new
      where
        err = faildoc $ text "Unknown struct field" <+> ppr f

assign (ArrayR mv) (ArrayC v) = do
    mv' <- V.unsafeThaw v
    MV.copy mv mv'

assign (IdxR mv i) val =
    val `seq` MV.write mv i val

assign (ArrayRefR mv) (ArrayC v) =
    loop 0 (MV.length mv)
  where
    loop :: Int -> Int -> m ()
    loop !i !len | i >= len =
        return ()

    loop i len = do
        let x =  v V.! i
        ref   <- MV.read mv i
        x `seq` assign ref x
        loop (i+1) len

assign val1 val2 =
  faildoc $ text "Cannot assign" <+> ppr val2 <+> text "to" <+> ppr val1

evalDecl :: forall a s m . (s ~ PrimState m, MonadTcRef m)
       => LocalDecl -> I s m a -> I s m a
evalDecl (LetLD v _ e _) k = do
    val <- evalExp e
    extendVals [(bVar v, val)] k

evalDecl (LetRefLD v tau e _) k = do
    ref <- evalInit e
    extendRefs [(bVar v, ref)] k
  where
    evalInit :: Maybe Exp -> I s m (Ref s)
    evalInit Nothing  = defaultRef tau
    evalInit (Just e) = evalExp e >>= toRef

evalConst :: MonadTcRef m => Const -> I s m Val
evalConst (ReplicateC n c) = return $ ArrayC $ V.replicate n c
evalConst (EnumC tau)      = enumTypeArray tau >>= evalConst
evalConst c                = return c

evalRef :: forall s m . (s ~ PrimState m, MonadTcRef m)
        => Exp -> I s m (Ref s)
evalRef (VarE v _) =
    lookupRef v

evalRef (IdxE e1 e2 len _) = do
    ref <- evalRef e1
    i   <- evalExp e2 >>= fromIntV
    idxR ref i len

evalRef (ProjE e f _) = do
    ref <- evalRef e
    projR ref f

evalRef e =
    faildoc $ text "Expression is not a valid reference:" <+> ppr e

evalExp :: forall s m . (s ~ PrimState m, MonadTcRef m)
        => Exp -> I s m Val
evalExp (ConstE c _) =
    evalConst c

evalExp (VarE v _) =
    lookupVal v

evalExp e0@(UnopE op e _) = do
    val <- evalExp e
    unop op val
  where
    unop :: Unop -> Val -> I s m Val
    unop Lnot c | Just c' <- liftBool op not c =
        return  c'

    unop Bnot c | Just c' <- liftBits op complement c =
        return c'

    unop Neg c | Just c' <- liftNum op negate c =
        return c'

    unop (Cast tau) c | Just c' <- liftCast tau c =
        return c'

    unop Len (ArrayC v) =
        return $ intC $ V.length v

    unop _ _ =
        faildoc $ text "Could not evaluate" <+> ppr e0

evalExp e0@(BinopE op e1 e2 _) = do
    val1 <- evalExp e1
    val2 <- evalExp e2
    binop op val1 val2
  where
    binop :: Binop -> Val -> Val -> I s m Val
    binop Lt c1 c2 =
        return $ liftOrd op (<) c1 c2

    binop Le c1 c2 =
        return $ liftOrd op (<=) c1 c2

    binop Eq c1 c2 =
        return $ liftEq op (==) c1 c2

    binop Ge c1 c2 =
        return $ liftOrd op (>=) c1 c2

    binop Gt c1 c2 =
        return $ liftOrd op (>) c1 c2

    binop Ne c1 c2 =
        return $ liftEq op (/=) c1 c2

    binop Land (BoolC False) _ =
        return $ BoolC False

    binop Land _ val2 =
        return val2

    binop Lor (BoolC True) _ =
        return $ BoolC True

    binop Lor _ val2 =
        return val2

    binop Band c1 c2 | Just c' <- liftBits2 op (.&.) c1 c2 =
        return c'

    binop Bor c1 c2 | Just c' <- liftBits2 op (.|.) c1 c2 =
        return c'

    binop Bxor c1 c2 | Just c' <- liftBits2 op xor c1 c2 =
        return c'

    binop LshL c1 c2 | Just c' <- liftShift op shiftL c1 c2 =
        return c'

    binop AshR c1 c2 | Just c' <- liftShift op shiftR c1 c2 =
        return c'

    binop Add c1 c2 | Just c' <- liftNum2 op (+) c1 c2 =
        return c'

    binop Sub c1 c2 | Just c' <- liftNum2 op (-) c1 c2 =
        return c'

    binop Mul c1 c2 | Just c' <- liftNum2 op (*) c1 c2 =
        return c'

    binop Div c1 c2 | Just c' <- liftIntegral2 op quot c1 c2 =
        return c'

    binop Rem c1 c2 | Just c' <- liftIntegral2 op rem c1 c2 =
        return c'

    binop _ _ _ =
        faildoc $ text "Could not evaluate" <+> ppr e0

evalExp e0@(IfE e1 e2 e3 _) =
    evalExp e1 >>= go
  where
    go :: Val -> I s m Val
    go (BoolC True)  = evalExp e2
    go (BoolC False) = evalExp e3
    go _             = faildoc $ text "Could not evaluate" <+> ppr e0

evalExp (LetE decl e _) =
    evalDecl decl $
    evalExp e

evalExp (DerefE e _) =
    evalRef e >>= fromRef

evalExp (AssignE e1 e2 _) = do
    ref <- evalRef e1
    val <- evalExp e2
    assign ref val
    return UnitC

evalExp (WhileE e1 e2 _) =
    evalExp e1 >>= go
  where
    go :: Val -> I s m Val
    go (BoolC True) = do
        void $ evalExp e2
        evalExp e1 >>= go

    go (BoolC False) =
        return UnitC

    go val =
        faildoc $ text "Bad conditional:" <+> ppr val

evalExp (ForE _ v tau e1 e2 e3 _) = do
    i   <- evalExp e1 >>= fromIntV
    len <- evalExp e2 >>= fromIntV
    ref <- newRef $ intV tau i
    extendRefs [(v, ValR ref)] $
      loop ref i (i+len)
    return UnitC
  where
    loop :: IORef Val -> Int -> Int -> I s m ()
    loop !ref !i !end | i < end = do
        void $ evalExp e3
        writeRef ref $ intV tau (i+1)
        loop ref (i+1) end

    loop _ _ _ =
        return ()

evalExp (ArrayE es _) = do
    vals <- mapM evalExp es
    return $ ArrayC $ V.fromList vals

evalExp (IdxE e1 e2 len _) = do
    val1 <- evalExp e1
    val2 <- evalExp e2 >>= fromIntV
    idxV val1 val2 len

evalExp (StructE struct flds _) = do
    vals <- mapM evalExp es
    return $ StructC struct (fs `zip` vals)
  where
    fs :: [Field]
    es :: [Exp]
    (fs, es) = unzip  flds

evalExp (ProjE e f _) = do
    val <- evalExp e
    projV val f

evalExp (ReturnE _ e _) =
    evalExp e

evalExp (BindE WildV _ e1 e2 _) = do
    void $ evalExp e1
    evalExp e2

evalExp (BindE (TameV v) _ e1 e2 _) = do
    val1 <- evalExp e1
    extendVals [(bVar v, val1)] $
      evalExp e2

evalExp (LutE _ e) =
    evalExp e

evalExp e =
    faildoc $ text "Cannot evaluate" <+> ppr e

compileDecl :: forall a s m . (s ~ RealWorld, s ~ PrimState m, MonadTcRef m)
            => LocalDecl -> I s m (IO a) -> I s m (IO a)
compileDecl (LetLD v tau e _) k = do
    ref   <- defaultRef tau
    mval1 <- compileExp e
    mval2 <- extendRefs [(bVar v, ref)] k
    return $ do mval1 >>= assign ref
                mval2

compileDecl (LetRefLD v tau e _) k = do
    ref   <- defaultRef tau
    mval1 <- compileInit e
    mval2 <- extendRefs [(bVar v, ref)] k
    return $ do mval1 >>= assign ref
                mval2
  where
    compileInit :: Maybe Exp -> I s m (IO Val)
    compileInit Nothing  = do val <- defaultVal tau
                              return $ return val
    compileInit (Just e) = compileExp e

isRef :: Exp -> Bool
isRef VarE{}          = True
isRef (IdxE e1 _ _ _) = isRef e1
isRef (ProjE e _ _)   = isRef e
isRef _               = False

compileRef :: forall s m . (s ~ RealWorld, s ~ PrimState m, MonadTcRef m)
           => Exp -> I s m (IO (Ref s))
compileRef (VarE v _) = do
    ref <- lookupRef v
    return $ return ref

compileRef (IdxE e1 e2 len _) = do
    mref <- compileRef e1
    mi   <- compileExp e2
    return $ do ref <- mref
                i   <- mi >>= fromIntV
                idxR ref i len

compileRef (ProjE e f _) = do
    mref <- compileRef e
    return $ do ref <- mref
                projR ref f

compileRef e =
    faildoc $ text "Expression is not a valid reference:" <+> ppr e

compileExp :: forall s m . (s ~ RealWorld, s ~ PrimState m, MonadTcRef m)
           => Exp -> I s m (IO Val)
compileExp (ConstE c _) = do
    val <- evalConst c
    return $ return val

compileExp (VarE v _) = do
    ref <- lookupRef v
    return $ fromRef ref

compileExp e0@(UnopE op e _) = do
    mval <- compileExp e
    return $ mval >>= unop op
  where
    unop :: Unop -> Val -> IO Val
    unop Lnot c | Just c' <- liftBool op not c =
        return c'

    unop Bnot c | Just c' <- liftBits op complement c =
        return c'

    unop Neg c | Just c' <- liftNum op negate c =
        return c'

    unop (Cast tau) c | Just c' <- liftCast tau c =
        return c'

    unop Len (ArrayC v) =
        return $ intC $ V.length v

    unop _ _ =
        faildoc $ text "Could not evaluate" <+> ppr e0

compileExp e0@(BinopE op e1 e2 _) = do
    mval1 <- compileExp e1
    mval2 <- compileExp e2
    return $ do val1 <- mval1
                val2 <- mval2
                binop op val1 val2
  where
    binop :: Binop -> Val -> Val -> IO Val
    binop Lt c1 c2 =
        return $ liftOrd op (<) c1 c2

    binop Le c1 c2 =
        return $ liftOrd op (<=) c1 c2

    binop Eq c1 c2 =
        return $ liftEq op (==) c1 c2

    binop Ge c1 c2 =
        return $ liftOrd op (>=) c1 c2

    binop Gt c1 c2 =
        return $ liftOrd op (>) c1 c2

    binop Ne c1 c2 =
        return $ liftEq op (/=) c1 c2

    binop Land (BoolC False) _ =
        return $ BoolC False

    binop Land _ val2 =
        return val2

    binop Lor (BoolC True) _ =
        return $ BoolC True

    binop Lor _ val2 =
        return val2

    binop Band c1 c2 | Just c' <- liftBits2 op (.&.) c1 c2 =
        return c'

    binop Bor c1 c2 | Just c' <- liftBits2 op (.|.) c1 c2 =
        return c'

    binop Bxor c1 c2 | Just c' <- liftBits2 op xor c1 c2 =
        return c'

    binop LshL c1 c2 | Just c' <- liftShift op shiftL c1 c2 =
        return c'

    binop AshR c1 c2 | Just c' <- liftShift op shiftR c1 c2 =
        return c'

    binop Add c1 c2 | Just c' <- liftNum2 op (+) c1 c2 =
        return c'

    binop Sub c1 c2 | Just c' <- liftNum2 op (-) c1 c2 =
        return c'

    binop Mul c1 c2 | Just c' <- liftNum2 op (*) c1 c2 =
        return c'

    binop Div c1 c2 | Just c' <- liftIntegral2 op quot c1 c2 =
        return c'

    binop Rem c1 c2 | Just c' <- liftIntegral2 op rem c1 c2 =
        return c'

    binop _ _ _ =
        faildoc $ text "Could not evaluate" <+> ppr e0

compileExp e0@(IfE e1 e2 e3 _) = do
    mval1 <- compileExp e1
    mval2 <- compileExp e2
    mval3 <- compileExp e3
    return $ do val1 <- mval1
                case val1 of
                  BoolC True  -> mval2
                  BoolC False -> mval3
                  _ -> faildoc $ text "Could not evaluate" <+> ppr e0

compileExp (LetE decl e _) =
    compileDecl decl $
    compileExp e

compileExp (DerefE e _) = do
    mref <- compileRef e
    return $ mref >>= fromRef

compileExp (AssignE e1 e2 _) = do
    mref <- compileRef e1
    mval <- compileExp e2
    return $ do ref <- mref
                val <- mval
                assign ref val
                return UnitC

compileExp (WhileE e1 e2 _) = do
    mval1 <- compileExp e1
    mval2 <- compileExp e2
    let go :: Val -> IO Val
        go (BoolC True) = do
            void mval2
            mval1 >>= go

        go (BoolC False) =
            return UnitC

        go val =
            faildoc $ text "Bad conditional:" <+> ppr val
    return $ mval1 >>= go

compileExp (ForE _ v tau e1 e2 e3 _) = do
    mi    <- compileExp e1
    mlen  <- compileExp e2
    ref   <- newRef $ error "naughty"
    mbody <- extendRefs [(v, ValR ref)] $
             compileExp e3
    let loop :: Int -> Int -> IO Val
        loop !i !end | i < end = do
            void mbody
            writeRef ref $ intV tau (i+1)
            loop (i+1) end

        loop _ _ =
            return UnitC
    return $ do i   <- mi   >>= fromIntV
                len <- mlen >>= fromIntV
                writeRef ref $ intV tau i
                loop i (i+len)

compileExp (ArrayE es _) = do
    mvals <- mapM compileExp es
    return $ do vals <- sequence mvals
                return $ ArrayC $ V.fromList vals

compileExp e@IdxE{} | isRef e = do
    mref <- compileRef e
    return $ mref >>= fromRef

compileExp (IdxE e1 e2 len _) = do
    mval1 <- compileExp e1
    mval2 <- compileExp e2
    return $ do arr <- mval1
                i   <- mval2 >>= fromIntV
                idxV arr i len

compileExp (StructE struct flds _) = do
    mvals <- mapM compileExp es
    return $ do vals <- sequence mvals
                return $ StructC struct $ fs `zip` vals
  where
    (fs, es) = unzip flds

compileExp e@ProjE{} | isRef e = do
    mref <- compileRef e
    return $  mref >>= fromRef

compileExp (ProjE e f _) = do
    mval <- compileExp e
    return $ do val <- mval
                projV val f

compileExp (ReturnE _ e _) =
    compileExp e

compileExp (BindE WildV _ e1 e2 _) = do
    mval1 <- compileExp e1
    mval2 <- compileExp e2
    return $ do void mval1
                mval2

compileExp (BindE (TameV v) tau e1 e2 _) = do
    mval1 <- compileExp e1
    ref   <- defaultRef tau
    mval2 <- extendRefs [(bVar v, ref)] $
             compileExp e2
    return $ do val1 <- mval1
                assign ref val1
                mval2

compileExp (LutE _ e) =
    compileExp e

compileExp e =
    faildoc $ text "Cannot evaluate" <+> ppr e
