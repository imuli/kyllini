{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : KZC.Expr.Syntax
-- Copyright   : (c) 2015-2017 Drexel University
-- License     : BSD-style
-- Author      : Geoffrey Mainland <mainland@drexel.edu>
-- Maintainer  : Geoffrey Mainland <mainland@drexel.edu>

module KZC.Expr.Syntax (
    module KZC.Traits,
    Var(..),
    WildVar(..),
    Field(..),
    Struct(..),
    TyVar(..),

    IP(..),
    ipWidth,
    ipIsSigned,
    ipIsIntegral,

    FP(..),
    fpWidth,

    Program(..),
    Import(..),
    Decl(..),
    Const(..),
    Exp(..),
    GenInterval(..),
    Stm(..),

    UnrollAnn(..),
    mayUnroll,
    InlineAnn(..),
    PipelineAnn(..),
    VectAnn(..),

    Unop(..),
    Binop(..),

    StructDef(..),
    Type(..),
    Omega(..),
    Kind(..),

    isComplexStruct,

#if !defined(ONLY_TYPEDEFS)
    LiftedBool(..),
    LiftedEq(..),
    LiftedOrd(..),
    LiftedNum(..),
    LiftedIntegral(..),
    LiftedBits(..),
    LiftedCast(..),

    renormalize,

    pprTypeSig,
    pprKindSig,
    pprFunDecl
#endif /* !defined(ONLY_TYPEDEFS) */
  ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>), (<*>), pure)
#endif /* !MIN_VERSION_base(4,8,0) */
import Control.Monad.Reader
import Data.Bits
#if !MIN_VERSION_base(4,8,0)
import Data.Foldable (foldMap)
#endif /* !MIN_VERSION_base(4,8,0) */
import Data.Loc
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import Data.Monoid
import Data.String
import Data.Symbol
import Data.Vector (Vector)
import qualified Data.Vector as V
import Text.PrettyPrint.Mainland

import KZC.Name
import KZC.Platform
import KZC.Traits
import qualified KZC.Util.EnumSet as Set
import KZC.Util.Pretty
import KZC.Util.SetLike
import KZC.Util.Staged
import KZC.Util.Summary
import KZC.Util.Uniq
import KZC.Vars

newtype Var = Var Name
  deriving (Eq, Ord, Read, Show)

instance IsString Var where
    fromString s = Var (fromString s)

instance Named Var where
    namedSymbol (Var n) = namedSymbol n

    mapName f (Var n) = Var (f n)

instance Gensym Var where
    gensymAt s l = Var <$> gensymAt s (locOf l)

    uniquify (Var n) = Var <$> uniquify n

data WildVar = WildV
             | TameV Var
  deriving (Eq, Ord, Read, Show)

newtype Field = Field Name
  deriving (Eq, Ord, Read, Show)

instance IsString Field where
    fromString s = Field (fromString s)

instance Named Field where
    namedSymbol (Field n) = namedSymbol n

    mapName f (Field n) = Field (f n)

instance Gensym Field where
    gensymAt s l = Field <$> gensymAt s (locOf l)

    uniquify (Field n) = Field <$> uniquify n

newtype Struct = Struct Name
  deriving (Eq, Ord, Read, Show)

instance IsString Struct where
    fromString s = Struct (fromString s)

instance Named Struct where
    namedSymbol (Struct n) = namedSymbol n

    mapName f (Struct n) = Struct (f n)

instance Gensym Struct where
    gensymAt s l = Struct <$> gensymAt s (locOf l)

    uniquify (Struct n) = Struct <$> uniquify n

newtype TyVar = TyVar Name
  deriving (Eq, Ord, Read, Show)

instance IsString TyVar where
    fromString s = TyVar (fromString s)

instance Named TyVar where
    namedSymbol (TyVar n) = namedSymbol n

    mapName f (TyVar n) = TyVar (f n)

instance Gensym TyVar where
    gensymAt s l = TyVar <$> gensymAt s (locOf l)

    uniquify (TyVar n) = TyVar <$> uniquify n

-- | Fixed-point format.
data IP = I {-# UNPACK #-} !Int
        | U {-# UNPACK #-} !Int
  deriving (Eq, Ord, Read, Show)

ipWidth :: IP -> Int
ipWidth (I w) = w
ipWidth (U w) = w

ipIsSigned :: IP -> Bool
ipIsSigned I{} = True
ipIsSigned U{} = False

ipIsIntegral :: IP -> Bool
ipIsIntegral I{} = True
ipIsIntegral U{} = True

-- | Floating-point format.
data FP = FP16
        | FP32
        | FP64
  deriving (Eq, Ord, Read, Show)

fpWidth :: FP -> Int
fpWidth FP16 = 16
fpWidth FP32 = 32
fpWidth FP64 = 64

data Program = Program [Import] [Decl]
  deriving (Eq, Ord, Read, Show)

data Import = Import ModuleName
  deriving (Eq, Ord, Read, Show)

data Decl = LetD Var Type Exp !SrcLoc
          | LetRefD Var Type (Maybe Exp) !SrcLoc
          | LetFunD Var [(TyVar, Kind)] [(Var, Type)] Type Exp !SrcLoc
          | LetExtFunD Var [(TyVar, Kind)] [(Var, Type)] Type !SrcLoc
          | LetStructD Struct [(Field, Type)] !SrcLoc
  deriving (Eq, Ord, Read, Show)

data Const = UnitC
           | BoolC !Bool
           | FixC !IP {-# UNPACK #-} !Int
           | FloatC !FP {-# UNPACK #-} !Double
           | StringC String
           | ArrayC !(Vector Const)
           | ReplicateC Int Const
           | EnumC Type
           | StructC Struct [(Field, Const)]
  deriving (Eq, Ord, Read, Show)

data Exp = ConstE Const !SrcLoc
         | VarE Var !SrcLoc
         | UnopE Unop Exp !SrcLoc
         | BinopE Binop Exp Exp !SrcLoc
         | IfE Exp Exp Exp !SrcLoc
         | LetE Decl Exp !SrcLoc
         -- Functions
         | CallE Var [Type] [Exp] !SrcLoc
         -- References
         | DerefE Exp !SrcLoc
         | AssignE Exp Exp !SrcLoc
         -- Loops
         | WhileE Exp Exp !SrcLoc
         | ForE UnrollAnn Var Type (GenInterval Exp) Exp !SrcLoc
         -- Arrays
         | ArrayE [Exp] !SrcLoc
         | IdxE Exp Exp (Maybe Int) !SrcLoc
         -- Structs Struct
         | StructE Struct [(Field, Exp)] !SrcLoc
         | ProjE Exp Field !SrcLoc
         -- Print
         | PrintE Bool [Exp] !SrcLoc
         | ErrorE Type String !SrcLoc
         -- Computations
         | ReturnE InlineAnn Exp !SrcLoc
         | BindE WildVar Type Exp Exp !SrcLoc
         | TakeE Type !SrcLoc
         | TakesE Int Type !SrcLoc
         | EmitE Exp !SrcLoc
         | EmitsE Exp !SrcLoc
         | RepeatE VectAnn Exp !SrcLoc
         | ParE PipelineAnn Type Exp Exp !SrcLoc
  deriving (Eq, Ord, Read, Show)

data GenInterval a -- | The interval @e1..e2@, /inclusive/ of @e2@.
                   = FromToInclusive a a !SrcLoc
                   -- | The interval @e1..e2@, /exclusive/ of @e2@.
                   | FromToExclusive a a !SrcLoc
                   -- | The interval that starts at @e1@ and has length @e2@.
                   | StartLen a a !SrcLoc
  deriving (Eq, Ord, Read, Show, Functor, Foldable, Traversable)

data Stm d v e = ReturnS InlineAnn e !SrcLoc
               | LetS d !SrcLoc
               | BindS (Maybe v) Type e !SrcLoc
               | ExpS e !SrcLoc
  deriving (Eq, Ord, Read, Show)

data UnrollAnn = Unroll     -- ^ Always unroll
               | NoUnroll   -- ^ Never unroll
               | AutoUnroll -- ^ Let the compiler choose when to unroll
  deriving (Enum, Eq, Ord, Read, Show)

-- | Return 'True' if annotation indicates loop may be unrolled.
mayUnroll :: UnrollAnn -> Bool
mayUnroll Unroll     = True
mayUnroll NoUnroll   = False
mayUnroll AutoUnroll = True

data InlineAnn = Inline     -- ^ Always inline
               | NoInline   -- ^ Never inline
               | AutoInline -- ^ Let the compiler decide when to inline
  deriving (Enum, Eq, Ord, Read, Show)

data PipelineAnn = AlwaysPipeline -- ^ Always pipeline
                 | NoPipeline     -- ^ Never pipeline
                 | AutoPipeline   -- ^ Let the compiler decide when to pipeline
  deriving (Enum, Eq, Ord, Read, Show)

data VectAnn = AutoVect
             | Rigid Bool Int Int  -- ^ True == allow mitigations up, False ==
                                   -- disallow mitigations up
             | UpTo  Bool Int Int
  deriving (Eq, Ord, Read, Show)

data Unop = Lnot
          | Bnot
          | Neg
          | Cast Type
          | Bitcast Type
          | Len
  deriving (Eq, Ord, Read, Show)

data Binop = Eq
           | Ne
           | Lt
           | Le
           | Ge
           | Gt
           | Land
           | Lor
           | Band
           | Bor
           | Bxor
           | LshL
           | LshR
           | AshR
           | Add
           | Sub
           | Mul
           | Div
           | Rem
           | Pow
           | Cat -- ^ Array concatenation.
  deriving (Eq, Ord, Read, Show)

data StructDef = StructDef Struct [(Field, Type)] !SrcLoc
  deriving (Eq, Ord, Read, Show)

data Type = UnitT !SrcLoc
          | BoolT !SrcLoc
          | FixT IP !SrcLoc
          | FloatT FP !SrcLoc
          | StringT !SrcLoc
          | StructT Struct !SrcLoc
          | ArrT Type Type !SrcLoc
          | ST Omega Type Type Type !SrcLoc
          | RefT Type !SrcLoc
          | FunT [Type] Type !SrcLoc
          | NatT Int !SrcLoc
          | ForallT [(TyVar, Kind)] Type !SrcLoc
          | TyVarT TyVar !SrcLoc
  deriving (Eq, Ord, Read, Show)

data Omega = C Type
           | T
  deriving (Eq, Ord, Read, Show)

data Kind = TauK Traits -- ^ Base types, including arrays of base types
          | RhoK        -- ^ Reference types
          | OmegaK      -- ^ @C tau@ or @T@
          | MuK         -- ^ @ST omega tau tau tau@ types
          | PhiK        -- ^ Function types
          | NatK        -- ^ Type-level natural number
  deriving (Eq, Ord, Read, Show)

-- | @isComplexStruct s@ is @True@ if @s@ is a complex struct type.
isComplexStruct :: Struct -> Bool
isComplexStruct "complex"   = True
isComplexStruct "complex8"  = True
isComplexStruct "complex16" = True
isComplexStruct "complex32" = True
isComplexStruct "complex64" = True
isComplexStruct _           = False

#if !defined(ONLY_TYPEDEFS)
{------------------------------------------------------------------------------
 -
 - Staging
 -
 ------------------------------------------------------------------------------}

instance Num Const where
    x + y = fromMaybe err $ liftNum2 Add (+) x y
      where
        err = error "Num Const: + did not result in a constant"

    x - y = fromMaybe err $ liftNum2 Sub (-) x y
      where
        err = error "Num Const: - did not result in a constant"

    x * y =  fromMaybe err $ liftNum2 Mul (*) x y
      where
        err = error "Num Const: * did not result in a constant"

    negate x = fromMaybe err $ liftNum Neg negate x
      where
        err = error "Num Const: negate did not result in a constant"

    fromInteger i = FixC (I dEFAULT_INT_WIDTH) (fromIntegral i)

    abs _    = error "Num Const: abs not implemented"
    signum _ = error "Num Const: signum not implemented"

-- | A type to which operations on the 'Bool' type can be lifted.
class LiftedBool a b | a -> b where
    liftBool  :: Unop  -> (Bool -> Bool)         -> a -> b
    liftBool2 :: Binop -> (Bool -> Bool -> Bool) -> a -> a -> b

-- | A type to which operations on 'Eq' types can be lifted.
class LiftedEq a b | a -> b where
    liftEq :: Binop -> (forall a . Eq a => a -> a -> Bool) -> a -> a -> b

-- | A type to which operations on 'Ord' types can be lifted.
class LiftedOrd a b | a -> b where
    liftOrd :: Binop -> (forall a . Ord a => a -> a -> Bool) -> a -> a -> b

-- | A type to which operations on 'Num' types can be lifted.
class LiftedNum a b | a -> b where
    liftNum  :: Unop  -> (forall a . Num a => a -> a)      -> a -> b
    liftNum2 :: Binop -> (forall a . Num a => a -> a -> a) -> a -> a -> b

-- | A type to which operations on 'Integral' types can be lifted.
class LiftedIntegral a b | a -> b where
    liftIntegral2 :: Binop -> (forall a . Integral a => a -> a -> a) -> a -> a -> b

-- | A type to which operations on 'Bits' types can be lifted.
class LiftedBits a b | a -> b where
    liftBits  :: Unop  -> (forall a . Bits a => a -> a)        -> a -> b
    liftBits2 :: Binop -> (forall a . Bits a => a -> a -> a)   -> a -> a -> b
    liftShift :: Binop -> (forall a . Bits a => a -> Int -> a) -> a -> a -> b

-- | A type which can be cast.
class LiftedCast a b | a -> b where
    liftCast  :: Type -> a -> b

-- | Renormalize a constant, ensuring that integral constants are within their
-- bounds. We assume two's complement arithmetic.
renormalize :: Const -> Const
renormalize c@(FixC (I w) x)
    | x > max   = renormalize (FixC (I w) (x - 2^w))
    | x < min   = renormalize (FixC (I w) (x + 2^w))
    | otherwise = c
  where
    max, min :: Int
    max = 2^(w-1)-1
    min = -2^(w-1)

renormalize c@(FixC (U w) x)
    | x > max   = renormalize (FixC (U w) (x - 2^w))
    | x < 0     = renormalize (FixC (U w) (x + 2^w))
    | otherwise = c
  where
    max :: Int
    max = 2^w-1

renormalize c = c

instance LiftedBool Const (Maybe Const) where
    liftBool _ f (BoolC b) =
        Just $ BoolC (f b)

    liftBool _ _ _ =
        Nothing

    liftBool2 _ f (BoolC x) (BoolC y) =
        Just $ BoolC (f x y)

    liftBool2 _ _ _ _ =
        Nothing

instance LiftedEq Const Const where
    liftEq _ f x y = BoolC (f x y)

instance LiftedOrd Const Const where
    liftOrd _ f x y = BoolC (f x y)

instance LiftedNum Const (Maybe Const) where
    liftNum _op f (FixC ip x) =
        Just $ FixC ip (f x)

    liftNum _op f (FloatC fp x) =
        Just $ FloatC fp (f x)

    liftNum _op _f _c =
        Nothing

    liftNum2 _op f (FixC ip x) (FixC _ y) =
        Just $ renormalize $ FixC ip (f x y)

    liftNum2 _op f (FloatC fp x) (FloatC _ y) =
        Just $ FloatC fp (f x y)

    liftNum2 Add _f x@(StructC sn _) y@(StructC sn' _) | isComplexStruct sn && sn' == sn =
        Just $ complexC sn (a+c) (b+d)
      where
        (a, b) = uncomplexC x
        (c, d) = uncomplexC y

    liftNum2 Sub _f x@(StructC sn _) y@(StructC sn' _) | isComplexStruct sn && sn' == sn =
        Just $ complexC sn (a-c) (b-d)
      where
        (a, b) = uncomplexC x
        (c, d) = uncomplexC y

    liftNum2 Mul _f x@(StructC sn _) y@(StructC sn' _) | isComplexStruct sn && sn' == sn =
        Just $ complexC sn (a*c - b*d) (b*c + a*d)
      where
        (a, b) = uncomplexC x
        (c, d) = uncomplexC y

    liftNum2 _ _ _ _ =
        Nothing

instance LiftedIntegral Const (Maybe Const) where
    liftIntegral2 Div _ (FixC ip x) (FixC _ y) =
        Just $ FixC ip (fromIntegral (x `quot` y))

    liftIntegral2 Div _ (FloatC fp x) (FloatC _ y) =
        Just $ FloatC fp (x / y)

    liftIntegral2 Rem _ (FixC ip x) (FixC _ y) =
        Just $ FixC ip (fromIntegral (x `rem` y))

    liftIntegral2 Div _ x@(StructC sn _) y@(StructC sn' _) | isComplexStruct sn && sn' == sn = do
        re <- (a*c + b*d)/(c*c + d*d)
        im <- (b*c - a*d)/(c*c + d*d)
        return $ complexC sn re im
      where
        (a, b) = uncomplexC x
        (c, d) = uncomplexC y

        (/) :: Const -> Const -> Maybe Const
        x / y = liftIntegral2 Div quot x y

    liftIntegral2 _ _ _ _ =
        Nothing

instance LiftedCast Const (Maybe Const) where
    -- Cast to a bit type
    liftCast (FixT (U 1) _) (FixC _ x) =
        Just $ FixC (U 1) (if x == 0 then 0 else 1)

    -- Cast int to unsigned int
    liftCast (FixT (U w) _) (FixC _ x) =
        Just $ renormalize $ FixC (U w) x

    -- Cast int to signed int
    liftCast (FixT (I w) _) (FixC _ x) =
        Just $ renormalize $ FixC (I w) x

    -- Cast float to int
    liftCast (FixT ip _) (FloatC _ x) =
        Just $ FixC ip (fromIntegral (truncate x :: Integer))

    -- Cast signed int to float
    liftCast (FloatT fp _) (FixC I{} x) =
        Just $ FloatC fp (fromIntegral x)

    -- Cast unsigned int to float
    liftCast (FloatT fp _) (FixC U{} x) =
        Just $ FloatC fp (fromIntegral x)

    liftCast _ _ =
        Nothing

complexC :: Struct -> Const -> Const -> Const
complexC sname a b =
    StructC sname [("re", a), ("im", b)]

uncomplexC :: Const -> (Const, Const)
uncomplexC c@(StructC sname x) | isComplexStruct sname =
    fromMaybe err $ do
      re <- lookup "re" x
      im <- lookup "im" x
      return (re, im)
  where
    err = errordoc $ text "Bad complex value:" <+> ppr c

uncomplexC c =
    errordoc $ text "Not a complex value:" <+> ppr c

instance LiftedBits Const (Maybe Const) where
    liftBits _ f (FixC ip x) =
        Just $ FixC ip (f x)

    liftBits _ _ _ =
        Nothing

    liftBits2 _ f (FixC ip x) (FixC _ y) =
        Just $ FixC ip (f x y)

    liftBits2 _ _ _ _ =
        Nothing

    liftShift _ f (FixC ip x) (FixC _ y) =
        Just $ FixC ip (f x (fromIntegral y))

    liftShift _ _ _ _ =
        Nothing

{------------------------------------------------------------------------------
 -
 - Statements
 -
 ------------------------------------------------------------------------------}

expToStms :: Exp -> [Stm Decl Var Exp]
expToStms (LetE decl e l)               = LetS decl l : expToStms e
expToStms (ReturnE ann e l)             = [ReturnS ann e l]
expToStms (BindE WildV tau e1 e2 l)     = BindS Nothing tau e1 l : expToStms e2
expToStms (BindE (TameV v) tau e1 e2 l) = BindS (Just v) tau e1 l : expToStms e2
expToStms e                             = [ExpS e (srclocOf e)]

{------------------------------------------------------------------------------
 -
 - Summaries
 -
 ------------------------------------------------------------------------------}

instance Summary TyVar where
    summary alpha = text "type variable:" <+> align (ppr alpha)

instance Summary Var where
    summary v = text "variable:" <+> align (ppr v)

instance Summary Decl where
    summary (LetD v _ _ _)         = text "definition of" <+> ppr v
    summary (LetRefD v _ _ _)      = text "definition of" <+> ppr v
    summary (LetFunD v _ _ _ _ _)  = text "definition of" <+> ppr v
    summary (LetExtFunD v _ _ _ _) = text "definition of" <+> ppr v
    summary (LetStructD s _ _)     = text "definition of" <+> ppr s

instance Summary Exp where
    summary e = text "expression:" <+> align (ppr e)

instance Summary StructDef where
    summary (StructDef s _ _) = text "struct" <+> ppr s

{------------------------------------------------------------------------------
 -
 - Pretty printing
 -
 ------------------------------------------------------------------------------}

instance Pretty Var where
    ppr (Var n) = ppr n

instance Pretty Field where
    ppr (Field n) = ppr n

instance Pretty Struct where
    ppr (Struct n) = ppr n

instance Pretty TyVar where
    ppr (TyVar n) = ppr n

instance Pretty FP where
    ppr FP16 = text "16"
    ppr FP32 = text "32"
    ppr FP64 = text "64"

instance Pretty Program where
    ppr (Program imports decls) =
        ppr imports </>
        ppr decls

instance Pretty Import where
    ppr (Import mod) = text "import" <+> ppr mod

    pprList []      = empty
    pprList imports = semisep (map ppr imports)

instance Pretty Decl where
    pprPrec p (LetD v tau e _) =
        parensIf (p > appPrec) $
        text "let" <+> ppr v <+> text ":" <+> ppr tau <+> text "=" <+/> ppr e

    pprPrec p (LetRefD v tau Nothing _) =
        parensIf (p > appPrec) $
        text "let ref" <+> ppr v <+> text ":" <+> ppr tau

    pprPrec p (LetRefD v tau (Just e) _) =
        parensIf (p > appPrec) $
        text "let ref" <+> ppr v <+> text ":" <+> ppr tau <+> text "=" <+/> ppr e

    pprPrec p (LetFunD f tvks vbs tau e _) =
        parensIf (p > appPrec) $
        text "fun" <+> pprFunDecl f tvks vbs tau <> pprBody e

    pprPrec p (LetExtFunD f tvks vbs tau _) =
        parensIf (p > appPrec) $
        text "fun external" <+> pprFunDecl f tvks vbs tau

    pprPrec p (LetStructD s flds _) =
        parensIf (p > appPrec) $
        text "struct" <+> ppr s <+> text "=" <+> pprStruct semi colon flds

    pprList decls = stack (map ppr decls)

instance Pretty Const where
    pprPrec _ UnitC            = text "()"
    pprPrec _ (BoolC False)    = text "false"
    pprPrec _ (BoolC True)     = text "true"
    pprPrec _ (FixC (U 1) 0)   = text "'0"
    pprPrec _ (FixC (U 1) 1)   = text "'1"
    pprPrec _ (FixC I{} x)     = ppr x
    pprPrec _ (FixC U{} x)     = ppr x <> char 'u'
    pprPrec _ (FloatC _ f)     = ppr f
    pprPrec _ (StringC s)      = text (show s)
    pprPrec _ (StructC s flds) = ppr s <+> pprStruct comma equals flds
    pprPrec _ (ArrayC cs)
        | not (V.null cs) && V.all isBit cs = char '\'' <> folddoc (<>) (map bitDoc (reverse (V.toList cs)))
        | otherwise                         = text "arr" <+> enclosesep lbrace rbrace comma (map ppr (V.toList cs))
      where
        isBit :: Const -> Bool
        isBit (FixC (U 1) _) = True
        isBit _              = False

        bitDoc :: Const -> Doc
        bitDoc (FixC (U 1) 0) = char '0'
        bitDoc (FixC (U 1) 1) = char '1'
        bitDoc _              = error "Not a bit"

    pprPrec _ (ReplicateC n c) =
        braces $
        pprPrec appPrec1 c <+> text "x" <+> ppr n

    pprPrec _ (EnumC tau) =
        braces $
        ppr tau <+> text "..."

instance Pretty Exp where
    pprPrec _ (ConstE c _) =
        ppr c

    pprPrec _ (VarE v _) =
        ppr v

    pprPrec p (UnopE op@Cast{} e _) =
        parensIf (p > precOf op) $
        ppr op <> parens (ppr e)

    pprPrec p (UnopE op@Bitcast{} e _) =
        parensIf (p > precOf op) $
        ppr op <> parens (ppr e)

    pprPrec p (UnopE op e _) =
        parensIf (p > precOf op) $
        ppr op <> pprPrec (precOf op) e

    pprPrec p (BinopE op e1 e2 _) =
        infixop p op e1 e2

    pprPrec p (IfE e1 e2 e3 _) =
        parensIf (p >= appPrec) $
        text "if"   <+> pprPrec ifPrec1 e1 <+/>
        text "then" <+> pprPrec ifPrec1 e2 <+/>
        text "else" <+> pprPrec ifPrec1 e3

    pprPrec p (LetE decl body _) =
        parensIf (p > appPrec) $
        case body of
          LetE{} -> ppr decl <+> text "in" </> pprPrec doPrec1 body
          _      -> ppr decl </> text "in" <> pprBody body

    pprPrec _ (CallE f taus es _) =
        ppr f <> parens (commasep (map ppr taus ++ map ppr es))

    pprPrec _ (DerefE v _) =
        text "!" <> pprPrec appPrec1 v

    pprPrec p (AssignE v e _) =
        parensIf (p > appPrec) $
        ppr v <+> text ":=" <+/> pprPrec appPrec1 e

    pprPrec _ (WhileE e1 e2 _) =
        text "while" <+>
        group (pprPrec appPrec1 e1) <>
        pprBody e2

    pprPrec _ (ForE ann v tau gint e _) =
        ppr ann <+> text "for" <+> pprTypeSig v tau <+>
        text "in" <+> ppr gint <>
        pprBody e

    pprPrec _ (ArrayE es _) =
        text "arr" <+> enclosesep lbrace rbrace comma (map ppr es)

    pprPrec _ (IdxE e1 e2 Nothing _) =
        pprPrec appPrec1 e1 <> brackets (ppr e2)

    pprPrec _ (IdxE e1 e2 (Just i) _) =
        pprPrec appPrec1 e1 <> brackets (commasep [ppr e2, ppr i])

    pprPrec _ (StructE s fields _) =
        ppr s <+> pprStruct comma equals fields

    pprPrec _ (ProjE e f _) =
        pprPrec appPrec1 e <> text "." <> ppr f

    pprPrec _ (PrintE True es _) =
        text "println" <> parens (commasep (map (pprPrec appPrec1) es))

    pprPrec _ (PrintE False es _) =
        text "print" <> parens (commasep (map (pprPrec appPrec1) es))

    pprPrec _ (ErrorE tau s _) =
        text "error" <+> text "@" <> pprPrec appPrec1 tau <+> (text . show) s

    pprPrec p (ReturnE ann e _) =
        parensIf (p > appPrec) $
        ppr ann <+> text "return" <+> pprPrec appPrec1 e

    pprPrec _ e@BindE{} =
        ppr (expToStms e)

    pprPrec _ (TakeE tau _) =
        text "take" <+> text "@" <> pprPrec tyappPrec1 tau

    pprPrec p (TakesE i tau _) =
        parensIf (p > appPrec) $
        text "takes" <+> pprPrec appPrec1 i <+> text "@" <> pprPrec appPrec1 tau

    pprPrec p (EmitE e _) =
        parensIf (p > appPrec) $
        text "emit" <+> pprPrec appPrec1 e

    pprPrec p (EmitsE e _) =
        parensIf (p > appPrec) $
        text "emits" <+> pprPrec appPrec1 e

    pprPrec p (RepeatE ann e _) =
        parensIf (p > appPrec) $
        ppr ann <+> text "repeat" <> pprBody e

    pprPrec p (ParE ann tau e1 e2 _) =
        parensIf (p > parrPrec) $
        pprPrec parrPrec e1 <+>
        ppr ann <> text "@" <> pprPrec tyappPrec1 tau <+>
        pprPrec parrPrec1 e2

instance Pretty a => Pretty (GenInterval a) where
    ppr (FromToInclusive e1 e2 _) =
        brackets $ ppr e1 <> colon <> ppr e2

    ppr (FromToExclusive e1 e2 _) =
        ppr e1 <> text ".." <> ppr e2

    ppr (StartLen e1 e2 _) =
        brackets $ ppr e1 <> comma <+> ppr e2

instance Pretty PipelineAnn where
    ppr AlwaysPipeline = text "|>>>|"
    ppr _              = text ">>>"

instance (Pretty d, Pretty v, Pretty e) => Pretty (Stm d v e) where
    pprPrec p (ReturnS ann e _) =
        parensIf (p > appPrec) $
        ppr ann <+> text "return" <+> ppr e

    pprPrec _ (LetS d _) =
        ppr d

    pprPrec _ (BindS Nothing _ e _) =
        ppr e

    pprPrec _ (BindS (Just v) tau e _) =
        parens (ppr v <+> colon <+> ppr tau) <+>
        text "<-" <+> align (ppr e)

    pprPrec p (ExpS e _) =
        pprPrec p e

    pprList stms =
        embrace (map ppr stms)

instance Pretty UnrollAnn where
    ppr Unroll     = text "unroll"
    ppr NoUnroll   = text "nounroll"
    ppr AutoUnroll = empty

instance Pretty InlineAnn where
    ppr AutoInline = empty
    ppr NoInline   = text "noinline"
    ppr Inline     = text "forceinline"

instance Pretty VectAnn where
    ppr (Rigid True from to)  = text "!" <> ppr (Rigid False from to)
    ppr (Rigid False from to) = brackets (commasep [ppr from, ppr to])
    ppr (UpTo f from to)      = text "<=" <+> ppr (Rigid f from to)
    ppr AutoVect              = empty

instance Pretty WildVar where
    ppr WildV     = text "_"
    ppr (TameV v) = ppr v

instance Pretty Unop where
    ppr Lnot          = text "not" <> space
    ppr Bnot          = text "~"
    ppr Neg           = text "-"
    ppr Len           = text "length" <> space
    ppr (Cast tau)    = text "cast" <> langle <> ppr tau <> rangle
    ppr (Bitcast tau) = text "bitcast" <> langle <> ppr tau <> rangle

instance Pretty Binop where
    ppr Eq   = text "=="
    ppr Ne   = text "!="
    ppr Lt   = text "<"
    ppr Le   = text "<="
    ppr Ge   = text ">="
    ppr Gt   = text ">"
    ppr Land = text "&&"
    ppr Lor  = text "||"
    ppr Band = text "&"
    ppr Bor  = text "|"
    ppr Bxor = text "^"
    ppr LshL = text "<<"
    ppr LshR = text ">>>"
    ppr AshR = text ">>"
    ppr Add  = text "+"
    ppr Sub  = text "-"
    ppr Mul  = text "*"
    ppr Div  = text "/"
    ppr Rem  = text "%"
    ppr Pow  = text "**"
    ppr Cat  = text "++"

instance Pretty Type where
    pprPrec _ (UnitT _) =
        text "()"

    pprPrec _ (BoolT _) =
        text "bool"

    pprPrec _ (FixT (U 1) _) =
        text "bit"

    pprPrec _ (FixT (I w) _)
      | w == dEFAULT_INT_WIDTH = text "int"
      | otherwise              = text "int" <> ppr w

    pprPrec _ (FixT (U w) _)
      | w == dEFAULT_INT_WIDTH = text "uint"
      | otherwise              = text "uint" <> ppr w

    pprPrec _ (FloatT FP32 _) =
        text "float"

    pprPrec _ (FloatT FP64 _) =
        text "double"

    pprPrec _ (FloatT w _) =
        text "float" <> ppr w

    pprPrec _ (StringT _) =
        text "string"

    pprPrec p (RefT tau _) =
        parensIf (p > tyappPrec) $
        text "ref" <+> pprPrec tyappPrec1 tau

    pprPrec p (StructT s _) =
        parensIf (p > tyappPrec) $
        text "struct" <+> ppr s

    pprPrec p (ArrT ind tau@StructT{} _) =
        parensIf (p > tyappPrec) $
        ppr tau <> brackets (ppr ind)

    pprPrec _ (ArrT ind tau _) =
        ppr tau <> brackets (ppr ind)

    pprPrec p (ST omega tau1 tau2 tau3 _) =
        parensIf (p > tyappPrec) $
        text "ST" <+> pprPrec tyappPrec1 omega
                  <+> pprPrec tyappPrec1 tau1
                  <+> pprPrec tyappPrec1 tau2
                  <+> pprPrec tyappPrec1 tau3

    pprPrec p (FunT taus tau _) =
        parensIf (p > arrowPrec) $
        group $
        parens (commasep (map ppr taus)) <+>
        text "->" </>
        pprPrec arrowPrec1 tau

    pprPrec _ (NatT i _) =
        ppr i

    pprPrec p (ForallT tvks (ST omega tau1 tau2 tau3 _) _) =
        parensIf (p > tyappPrec) $
        text "ST" <>  pprForall tvks
                  <+> pprPrec tyappPrec1 omega
                  <+> pprPrec tyappPrec1 tau1
                  <+> pprPrec tyappPrec1 tau2
                  <+> pprPrec tyappPrec1 tau3

    pprPrec _ (ForallT tvks tau _) =
        pprForall tvks <> ppr tau

    pprPrec _ (TyVarT tv _) =
        ppr tv

instance Pretty Omega where
    pprPrec p (C tau) =
        parensIf (p > tyappPrec) $
        text "C" <+> pprPrec tyappPrec1 tau

    pprPrec _ T =
        text "T"

instance Pretty Kind where
    ppr (TauK ts) | nullTraits ts = text "tau"
                  | otherwise     = ppr ts

    ppr RhoK   = text "rho"
    ppr OmegaK = text "omega"
    ppr MuK    = text "mu"
    ppr PhiK   = text "phi"
    ppr NatK   = text "N"

-- | Pretty-print a forall quantifier
pprForall :: [(TyVar, Kind)] -> Doc
pprForall []   = empty
pprForall tvks = angles $ commasep (map pprKindSig tvks)

-- | Pretty-print a thing with a type signature
pprTypeSig :: Pretty a => a -> Type -> Doc
pprTypeSig v tau = parens (ppr v <+> colon <+> ppr tau)

-- | Pretty-print a thing with a kind signature
pprKindSig :: Pretty a => (a, Kind) -> Doc
pprKindSig (tau, TauK traits)
    | Set.null traits = ppr tau
    | otherwise       = parens (ppr tau <+> colon <+> ppr traits)

pprKindSig (tau, kappa) =
    parens (ppr tau <+> colon <+> ppr kappa)

-- | Pretty-print a function declaration.
pprFunDecl :: Var -> [(TyVar, Kind)] -> [(Var, Type)] -> Type -> Doc
pprFunDecl f tvks vbs tau_ret =
    group $
    nest 2 $
    ppr f <>
    pprForall tvks <>
    parens (commasep (map pprArg vbs)) <+>
    text "->" </>
    ppr tau_ret
  where
    pprArg :: (Var, Type) -> Doc
    pprArg (v, tau) = ppr v <+> colon <+> ppr tau

pprBody :: Exp -> Doc
pprBody e = softline <> ppr (expToStms e)

-- %left '&&' '||'
-- %left '==' '!='
-- %left '|'
-- %left '^'
-- %left '&'
-- %left '<' '<=' '>' '>='
-- %left '<<' '>>'
-- %left '+' '-'
-- %left '*' '/' '%'
-- %left '**'
-- %left 'length'
-- %left '~' 'not' NEG

instance HasFixity Binop where
    fixity Eq   = infixl_ 2
    fixity Ne   = infixl_ 2
    fixity Lt   = infixl_ 6
    fixity Le   = infixl_ 6
    fixity Ge   = infixl_ 6
    fixity Gt   = infixl_ 6
    fixity Land = infixl_ 1
    fixity Lor  = infixl_ 1
    fixity Band = infixl_ 5
    fixity Bor  = infixl_ 3
    fixity Bxor = infixl_ 4
    fixity LshL = infixl_ 7
    fixity LshR = infixl_ 7
    fixity AshR = infixl_ 7
    fixity Add  = infixl_ 8
    fixity Sub  = infixl_ 8
    fixity Mul  = infixl_ 9
    fixity Div  = infixl_ 9
    fixity Rem  = infixl_ 9
    fixity Pow  = infixl_ 10
    fixity Cat  = infixr_ 2

instance HasFixity Unop where
    fixity Lnot        = infixr_ 12
    fixity Bnot        = infixr_ 12
    fixity Neg         = infixr_ 12
    fixity Len         = infixr_ 11
    fixity (Cast _)    = infixr_ 10
    fixity (Bitcast _) = infixr_ 10

{------------------------------------------------------------------------------
 -
 - Free type variables
 -
 ------------------------------------------------------------------------------}

instance Fvs Type TyVar where
    fvs UnitT{}                      = mempty
    fvs BoolT{}                      = mempty
    fvs FixT{}                       = mempty
    fvs FloatT{}                     = mempty
    fvs StringT{}                    = mempty
    fvs (StructT _ _)                = mempty
    fvs (ArrT _ tau _)               = fvs tau
    fvs (ST  omega tau1 tau2 tau3 _) = fvs omega <> fvs tau1 <> fvs tau2 <> fvs tau3
    fvs (RefT tau _)                 = fvs tau
    fvs (FunT taus tau _)            = fvs taus <> fvs tau
    fvs NatT{}                       = mempty
    fvs (ForallT tvks tau _)         = fvs tau <\\> fromList (map fst tvks)
    fvs (TyVarT tv _)                = singleton tv

instance Fvs Omega TyVar where
    fvs (C tau) = fvs tau
    fvs T       = mempty

instance Fvs Type n => Fvs [Type] n where
    fvs = foldMap fvs

{------------------------------------------------------------------------------
 -
 - Free variables
 -
 ------------------------------------------------------------------------------}

instance Binders WildVar Var where
    binders WildV     = mempty
    binders (TameV v) = singleton v

instance Fvs Decl Var where
    fvs (LetD v _ e _)          = delete v (fvs e)
    fvs (LetRefD v _ e _)       = delete v (fvs e)
    fvs (LetFunD v _ vbs _ e _) = delete v (fvs e) <\\> fromList (map fst vbs)
    fvs LetExtFunD{}            = mempty
    fvs LetStructD{}            = mempty

instance Binders Decl Var where
    binders (LetD v _ _ _)         = singleton v
    binders (LetRefD v _ _ _)      = singleton v
    binders (LetFunD v _ _ _ _ _)  = singleton v
    binders (LetExtFunD v _ _ _ _) = singleton v
    binders LetStructD{}           = mempty

instance Fvs Exp Var where
    fvs ConstE{}              = mempty
    fvs (VarE v _)            = singleton v
    fvs (UnopE _ e _)         = fvs e
    fvs (BinopE _ e1 e2 _)    = fvs e1 <> fvs e2
    fvs (IfE e1 e2 e3 _)      = fvs e1 <> fvs e2 <> fvs e3
    fvs (LetE decl body _)    = fvs decl <> (fvs body <\\> binders decl)
    fvs (CallE f _ es _)      = singleton f <> fvs es
    fvs (DerefE e _)          = fvs e
    fvs (AssignE e1 e2 _)     = fvs e1 <> fvs e2
    fvs (WhileE e1 e2 _)      = fvs e1 <> fvs e2
    fvs (ForE _ v _ gint e _) = fvs gint <> delete v (fvs e)
    fvs (ArrayE es _)         = fvs es
    fvs (IdxE e1 e2 _ _)      = fvs e1 <> fvs e2
    fvs (StructE _ flds _)    = fvs (map snd flds)
    fvs (ProjE e _ _)         = fvs e
    fvs (PrintE _ es _)       = fvs es
    fvs ErrorE{}              = mempty
    fvs (ReturnE _ e _)       = fvs e
    fvs (BindE wv _ e1 e2 _)  = fvs e1 <> (fvs e2 <\\> binders wv)
    fvs TakeE{}               = mempty
    fvs TakesE{}              = mempty
    fvs (EmitE e _)           = fvs e
    fvs (EmitsE e _)          = fvs e
    fvs (RepeatE _ e _)       = fvs e
    fvs (ParE _ _ e1 e2 _)    = fvs e1 <> fvs e2

instance Fvs Exp v => Fvs [Exp] v where
    fvs = foldMap fvs

instance Fvs e v => Fvs (GenInterval e) v where
    fvs (FromToInclusive e1 e2 _) = fvs e1 <> fvs e2
    fvs (FromToExclusive e1 e2 _) = fvs e1 <> fvs e2
    fvs (StartLen e1 e2 _)        = fvs e1 <> fvs e2

{------------------------------------------------------------------------------
 -
 - All variables
 -
 ------------------------------------------------------------------------------}

instance HasVars WildVar Var where
    allVars WildV     = mempty
    allVars (TameV v) = singleton v

instance HasVars Decl Var where
    allVars (LetD v _ e _)           = singleton v <> allVars e
    allVars (LetRefD v _ e _)        = singleton v <> allVars e
    allVars (LetFunD v _ vbs _ e _)  = singleton v <> fromList (map fst vbs) <> allVars e
    allVars (LetExtFunD v _ vbs _ _) = singleton v <> fromList (map fst vbs)
    allVars LetStructD{}             = mempty

instance HasVars Exp Var where
    allVars ConstE{}              = mempty
    allVars (VarE v _)            = singleton v
    allVars (UnopE _ e _)         = allVars e
    allVars (BinopE _ e1 e2 _)    = allVars e1 <> allVars e2
    allVars (IfE e1 e2 e3 _)      = allVars e1 <> allVars e2 <> allVars e3
    allVars (LetE decl body _)    = allVars decl <> allVars body
    allVars (CallE f _ es _)      = singleton f <> allVars es
    allVars (DerefE e _)          = allVars e
    allVars (AssignE e1 e2 _)     = allVars e1 <> allVars e2
    allVars (WhileE e1 e2 _)      = allVars e1 <> allVars e2
    allVars (ForE _ v _ gint e _) = singleton v <> allVars gint <> allVars e
    allVars (ArrayE es _)         = allVars es
    allVars (IdxE e1 e2 _ _)      = allVars e1 <> allVars e2
    allVars (StructE _ flds _)    = allVars (map snd flds)
    allVars (ProjE e _ _)         = allVars e
    allVars (PrintE _ es _)       = allVars es
    allVars ErrorE{}              = mempty
    allVars (ReturnE _ e _)       = allVars e
    allVars (BindE wv _ e1 e2 _)  = allVars wv <> allVars e1 <> allVars e2
    allVars TakeE{}               = mempty
    allVars TakesE{}              = mempty
    allVars (EmitE e _)           = allVars e
    allVars (EmitsE e _)          = allVars e
    allVars (RepeatE _ e _)       = allVars e
    allVars (ParE _ _ e1 e2 _)    = allVars e1 <> allVars e2

instance HasVars e v => HasVars (GenInterval e) v where
    allVars (FromToInclusive e1 e2 _) = allVars e1 <> allVars e2
    allVars (FromToExclusive e1 e2 _) = allVars e1 <> allVars e2
    allVars (StartLen e1 e2 _)        = allVars e1 <> allVars e2

{------------------------------------------------------------------------------
 -
 - Polymorphic substitution
 -
 ------------------------------------------------------------------------------}

instance Subst a b Exp => Subst a b (Field, Exp) where
    substM (f, e) =
        (,) <$> pure f <*> substM e

instance Subst a b Type => Subst a b (Var, Type) where
    substM (f, e) =
        (,) <$> pure f <*> substM e

{------------------------------------------------------------------------------
 -
 - Type substitution
 -
 ------------------------------------------------------------------------------}

instance Subst Type TyVar Type where
    substM tau@UnitT{} =
        pure tau

    substM tau@BoolT{} =
        pure tau

    substM tau@FixT{} =
        pure tau

    substM tau@FloatT{} =
        pure tau

    substM tau@StringT{} =
        pure tau

    substM tau@StructT{} =
        pure tau

    substM (ArrT nat tau l) =
        ArrT <$> substM nat <*> substM tau <*> pure l

    substM (ST omega tau1 tau2 tau3 l) =
        ST <$> substM omega <*> substM tau1 <*> substM tau2 <*> substM tau3 <*> pure l

    substM (RefT tau l) =
        RefT <$> substM tau <*> pure l

    substM (FunT taus tau l) =
        FunT <$> substM taus <*> substM tau <*> pure l

    substM tau@NatT{} =
        pure tau

    substM (ForallT tvks tau l) =
        freshen tvks $ \tvks' ->
        ForallT tvks' <$> substM tau <*> pure l

    substM tau@(TyVarT alpha _) = do
        (theta, _) <- ask
        return $ fromMaybe tau (Map.lookup alpha theta)

instance Subst Type TyVar Omega where
    substM (C tau) = C <$> substM tau
    substM T       = pure T

instance Subst Type TyVar Decl where
    substM (LetD v tau e l) =
        LetD v <$> substM tau <*> substM e <*> pure l

    substM (LetRefD v tau e l) =
        LetRefD v <$> substM tau <*> substM e <*> pure l

    substM (LetFunD v alphas vbs tau e l) =
        LetFunD v alphas <$> substM vbs <*> substM tau <*> substM e <*> pure l

    substM (LetExtFunD v alphas vbs tau l) =
        LetExtFunD v alphas <$> substM vbs <*> substM tau <*> pure l

    substM decl@LetStructD{} =
        pure decl

instance Subst Type TyVar Exp where
    substM e@ConstE{} =
        return e

    substM e@VarE{} =
        return e

    substM (UnopE op e l) =
        UnopE op <$> substM e <*> pure l

    substM (BinopE op e1 e2 l) =
        BinopE op <$> substM e1 <*> substM e2 <*> pure l

    substM (IfE e1 e2 e3 l) =
        IfE <$> substM e1 <*> substM e2 <*> substM e3 <*> pure l

    substM (LetE decl e l) =
        LetE <$> substM decl <*> substM e <*> pure l

    substM (CallE v taus es l) =
        CallE v taus <$> substM es <*> pure l

    substM (DerefE e l) =
        DerefE <$> substM e <*> pure l

    substM (AssignE e1 e2 l) =
        AssignE <$> substM e1 <*> substM e2 <*> pure l

    substM (WhileE e1 e2 l) =
        WhileE <$> substM e1 <*> substM e2 <*> pure l

    substM (ForE ann v tau gint e l) =
        ForE ann v <$> substM tau <*> substM gint <*> substM e <*> pure l

    substM (ArrayE es l) =
        ArrayE <$> substM es <*> pure l

    substM (IdxE e1 e2 i l) =
        IdxE <$> substM e1 <*> substM e2 <*> pure i <*> pure l

    substM (StructE s flds l) =
        StructE s <$> substM flds <*> pure l

    substM (ProjE e fld l) =
        ProjE <$> substM e <*> pure fld <*> pure l

    substM (PrintE nl es l) =
        PrintE nl <$> substM es <*> pure l

    substM (ErrorE tau str s) =
        ErrorE <$> substM tau <*> pure str <*> pure s

    substM (ReturnE ann e l) =
        ReturnE ann <$> substM e <*> pure l

    substM (BindE wv tau e1 e2 l) =
        BindE wv <$> substM tau <*> substM e1 <*> substM e2 <*> pure l

    substM (TakeE tau l) =
        TakeE <$> substM tau <*> pure l

    substM (TakesE i tau l) =
        TakesE i <$> substM tau <*> pure l

    substM (EmitE e l) =
        EmitE <$> substM e <*> pure l

    substM (EmitsE e l) =
        EmitsE <$> substM e <*> pure l

    substM (RepeatE ann e l) =
        RepeatE ann <$> substM e <*> pure l

    substM (ParE ann tau e1 e2 l) =
        ParE ann tau <$> substM e1 <*> substM e2 <*> pure l

instance Subst e v a => Subst e v (GenInterval a) where
    substM (FromToInclusive e1 e2 l) =
        FromToInclusive <$> substM e1 <*> substM e2 <*> pure l

    substM (FromToExclusive e1 e2 l) =
        FromToExclusive <$> substM e1 <*> substM e2 <*> pure l

    substM (StartLen e1 e2 l) =
        StartLen <$> substM e1 <*> substM e2 <*> pure l

{------------------------------------------------------------------------------
 -
 - Expression substitution
 -
 ------------------------------------------------------------------------------}

instance Subst Exp Var Exp where
    substM e@ConstE{} =
        return e

    substM e@(VarE v _) = do
        (theta, _) <- ask
        return $ fromMaybe e (Map.lookup v theta)

    substM (UnopE op e l) =
        UnopE op <$> substM e <*> pure l

    substM (BinopE op e1 e2 l) =
        BinopE op <$> substM e1 <*> substM e2 <*> pure l

    substM (IfE e1 e2 e3 l) =
        IfE <$> substM e1 <*> substM e2 <*> substM e3 <*> pure l

    substM (LetE decl e l) =
        freshen decl $ \decl' ->
        LetE decl' <$> substM e <*> pure l

    substM (CallE v alphas es l) = do
        (theta, _) <- ask
        v' <- case Map.lookup v theta of
                Nothing          -> return v
                Just (VarE v' _) -> return v'
                Just e           ->
                    faildoc $ "Cannot substitute expression" <+>
                    ppr e <+> text "for variable" <+> ppr v
        CallE v' alphas <$> substM es <*> pure l

    substM (DerefE e l) =
        DerefE <$> substM e <*> pure l

    substM (AssignE e1 e2 l) =
        AssignE <$> substM e1 <*> substM e2 <*> pure l

    substM (WhileE e1 e2 l) =
        WhileE <$> substM e1 <*> substM e2 <*> pure l

    substM (ForE ann v tau gint e l) = do
        gint' <- substM gint
        freshen v $ \v' ->
          ForE ann v' tau gint' <$> substM e <*> pure l

    substM (ArrayE es l) =
        ArrayE <$> substM es <*> pure l

    substM (IdxE e1 e2 i l) =
        IdxE <$> substM e1 <*> substM e2 <*> pure i <*> pure l

    substM (StructE s flds l) =
        StructE s <$> substM flds <*> pure l

    substM (ProjE e fld l) =
        ProjE <$> substM e <*> pure fld <*> pure l

    substM (PrintE nl es l) =
        PrintE nl <$> substM es <*> pure l

    substM e@ErrorE{} =
        pure e

    substM (ReturnE ann e l) =
        ReturnE ann <$> substM e <*> pure l

    substM (BindE wv tau e1 e2 l) = do
        e1' <- substM e1
        freshen wv $ \wv' ->
          BindE wv' tau e1' <$> substM e2 <*> pure l

    substM e@TakeE{} =
        pure e

    substM e@TakesE{} =
        pure e

    substM (EmitE e l) =
        EmitE <$> substM e <*> pure l

    substM (EmitsE e l) =
        EmitsE <$> substM e <*> pure l

    substM (RepeatE ann e l) =
        RepeatE ann <$> substM e <*> pure l

    substM (ParE ann tau e1 e2 l) =
        ParE ann tau <$> substM e1 <*> substM e2 <*> pure l

{------------------------------------------------------------------------------
 -
 - Freshening type variables
 -
 ------------------------------------------------------------------------------}

instance Freshen TyVar Type TyVar where
    freshen alpha@(TyVar n) =
        freshenV (namedString n) mkV mkE alpha
      where
        mkV :: String -> TyVar
        mkV s = TyVar n { nameSym = intern s }

        mkE :: TyVar -> Type
        mkE alpha = TyVarT alpha (srclocOf alpha)

instance Freshen (TyVar, Kind) Type TyVar where
    freshen (alpha, kappa) k =
        freshen alpha $ \alpha' -> k (alpha', kappa)

{------------------------------------------------------------------------------
 -
 - Freshening variables
 -
 ------------------------------------------------------------------------------}

instance Freshen Decl Exp Var where
    freshen (LetD v tau e l) k = do
        e' <- substM e
        freshen v $ \v' ->
          k (LetD v' tau e' l)

    freshen (LetRefD v tau e l) k = do
        e' <- substM e
        freshen v $ \v' ->
          k (LetRefD v' tau e' l)

    freshen (LetFunD v alphas vbs tau e l) k =
        freshen v   $ \v'   ->
        freshen vbs $ \vbs' -> do
        decl' <- LetFunD v' alphas vbs' tau <$> substM e <*> pure l
        k decl'

    freshen (LetExtFunD v alphas vbs tau l) k =
        freshen v   $ \v'   ->
        freshen vbs $ \vbs' -> do
        decl' <- LetExtFunD v' alphas vbs' tau <$> pure l
        k decl'

    freshen decl@LetStructD{} k =
        k decl

instance Freshen Var Exp Var where
    freshen v@(Var n) =
        freshenV (namedString n) mkV mkE v
      where
        mkV :: String -> Var
        mkV s = Var n { nameSym = intern s }

        mkE :: Var -> Exp
        mkE v = VarE v (srclocOf v)

instance Freshen (Var, Type) Exp Var where
    freshen (v, tau) k =
        freshen v $ \v' ->
        k (v', tau)

instance Freshen WildVar Exp Var where
    freshen WildV     k = k WildV
    freshen (TameV v) k = freshen v $ \v' -> k (TameV v')

{------------------------------------------------------------------------------
 -
 - Staging
 -
 ------------------------------------------------------------------------------}

instance IsEq Exp where
    e1 .==. e2 = BinopE Eq e1 e2 (e1 `srcspan` e2)
    e1 ./=. e2 = BinopE Ne e1 e2 (e1 `srcspan` e2)

instance IsOrd Exp where
    e1 .<.  e2 = BinopE Lt e1 e2 (e1 `srcspan` e2)
    e1 .<=. e2 = BinopE Le e1 e2 (e1 `srcspan` e2)
    e1 .>=. e2 = BinopE Ge e1 e2 (e1 `srcspan` e2)
    e1 .>.  e2 = BinopE Gt e1 e2 (e1 `srcspan` e2)

#include "KZC/Expr/Syntax-instances.hs"

#endif /* !defined(ONLY_TYPEDEFS) */
