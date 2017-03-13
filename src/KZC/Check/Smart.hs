{-# LANGUAGE CPP #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}

-- |
-- Module      :  KZC.Check.Smart
-- Copyright   :  (c) 2015-2017 Drexel University
-- License     :  BSD-style
-- Maintainer  :  mainland@drexel.edu

module KZC.Check.Smart (
    qualK,
    tauK,
    eqK,
    ordK,
    boolK,
    numK,
    intK,
    fracK,
    bitsK,

    tyVarT,
    metaT,

    unitT,
    boolT,
    bitT,
    intT,
    int8T,
    int16T,
    int32T,
    int64T,
    uintT,
    uint8T,
    uint16T,
    uint32T,
    uint64T,
    refT,
    arrT,
    stT,
    forallST,
    cT,
    funT,
    forallT,

    structName,

    isUnitT,
    isRefT,
    isPureT,
    isPureishT
  ) where

import Data.Loc
import Data.List (sort)

import qualified Language.Ziria.Syntax as Z

import KZC.Check.Types
import KZC.Platform

qualK :: [Trait] -> Kind
qualK ts = TauK (R (traits ts))

tauK :: Kind
tauK = qualK []

eqK :: Kind
eqK = qualK [EqR]

ordK :: Kind
ordK = qualK [OrdR]

boolK :: Kind
boolK = qualK [BoolR]

numK :: Kind
numK = qualK [NumR]

intK :: Kind
intK = qualK [IntegralR]

fracK :: Kind
fracK = qualK [FractionalR]

bitsK :: Kind
bitsK = qualK [BitsR]

tyVarT :: TyVar -> Type
tyVarT tv@(TyVar n) = TyVarT tv (srclocOf n)

metaT :: MetaTv -> Type
metaT mtv = MetaT mtv noLoc

unitT :: Type
unitT = UnitT noLoc

boolT :: Type
boolT = BoolT noLoc

bitT :: Type
bitT = FixT (U 1) noLoc

intT :: Type
intT = FixT (I dEFAULT_INT_WIDTH) noLoc

int8T :: Type
int8T = FixT (I 8) noLoc

int16T :: Type
int16T = FixT (I 16) noLoc

int32T :: Type
int32T = FixT (I 32) noLoc

int64T :: Type
int64T = FixT (I 64) noLoc

uintT :: Type
uintT = FixT (U dEFAULT_INT_WIDTH) noLoc

uint8T :: Type
uint8T = FixT (U 8) noLoc

uint16T :: Type
uint16T = FixT (U 16) noLoc

uint32T :: Type
uint32T = FixT (U 32) noLoc

uint64T :: Type
uint64T = FixT (U 64) noLoc

refT :: Type -> Type
refT tau = RefT tau (srclocOf tau)

arrT :: Type -> Type -> Type
arrT iota tau = ArrT iota tau (iota `srcspan` tau)

stT :: Type -> Type -> Type -> Type -> Type
stT omega sigma alpha beta =
    ST omega sigma alpha beta (omega `srcspan` sigma `srcspan` alpha `srcspan` beta)

forallST :: [TyVar] -> Type -> Type -> Type -> Type -> SrcLoc -> Type
forallST [] omega s a b l =
    ST omega s a b l

forallST alphas omega s a b l =
    ForallT (alphas `zip` repeat tauK) (ST omega s a b l) l

cT :: Type -> Type
cT nu = C nu (srclocOf nu)

funT :: [Tvk] -> [Type] -> Type -> SrcLoc -> Type
funT []   taus tau l = FunT taus tau l
funT tvks taus tau l = ForallT tvks (FunT taus tau l) l

forallT :: [Tvk] -> Type -> Type
forallT [] tau =
    tau

forallT tvks (ForallT tvks' tau l) =
    ForallT (tvks ++ tvks') tau (map fst tvks `srcspan` l)

forallT tvks tau =
    ForallT tvks tau (map fst tvks `srcspan` tau)

structName :: StructDef -> Z.Struct
structName (StructDef s _ _) = s

isUnitT :: Type -> Bool
isUnitT UnitT{} = True
isUnitT _       = False

isRefT :: Type -> Bool
isRefT RefT{} = True
isRefT _      = False

-- | Return 'True' if the type is pure.
isPureT :: Type -> Bool
isPureT (ForallT _ tau@ST{} _) = isPureT tau
isPureT ST{}                   = False
isPureT _                      = True

-- | @'isPureishT' tau@ returns 'True' if @tau@ is a "pureish" computation,
-- @False@ otherwise. A pureish computation may use references, but it may not
-- take or emit, so it has type @forall s a b . ST omega s a b@.
isPureishT :: Type -> Bool
isPureishT (ForallT tvks (ST _ (TyVarT s _) (TyVarT a _) (TyVarT b _) _) _) =
    alphas' == alphas
  where
    alphas, alphas' :: [TyVar]
    alphas  = sort $ map fst tvks
    alphas' = sort [s, a, b]

isPureishT (ForallT _ ST{} _) =
    False

isPureishT ST{} =
    False

isPureishT _ =
    True
