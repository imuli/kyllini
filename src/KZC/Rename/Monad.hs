{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      :  KZC.Rename.Monad
-- Copyright   :  (c) 2014-2017 Drexel University
-- License     :  BSD-style
-- Maintainer  :  mainland@drexel.edu

module KZC.Rename.Monad (
    liftRn,
    RnEnv(..),

    Rn(..),
    runRn,

    extendTyVars,
    lookupTyVar,

    extendVars,
    lookupVar,

    extendCompVars,
    lookupMaybeCompVar,

    inCompScope,
    inPureScope
  ) where

import Control.Monad.Exception
import Control.Monad.Reader
import Control.Monad.Ref
import Data.IORef
import qualified Data.Map as Map
import Text.PrettyPrint.Mainland

import KZC.Config
import KZC.Monad
import KZC.Rename.State
import KZC.Util.Env
import KZC.Util.Error
import KZC.Util.Trace
import KZC.Util.Uniq

import Language.Ziria.Syntax

-- | Run a @Rn@ computation in the @KZC@ monad and update the @Rn@ environment.
liftRn :: forall a . ((a -> Rn a) -> Rn a) -> KZC a
liftRn m = do
    eref <- asks rnenvref
    env  <- readRef eref
    runRn (m' eref) env
  where
    m' :: IORef RnEnv -> Rn a
    m' eref =
        m $ \x -> do
        ask >>= writeRef eref
        return x

newtype Rn a = Rn { unRn :: ReaderT RnEnv KZC a }
    deriving (Functor, Applicative, Monad, MonadIO,
              MonadRef IORef, MonadAtomicRef IORef,
              MonadReader RnEnv,
              MonadException,
              MonadUnique,
              MonadErr,
              MonadConfig,
              MonadTrace)

runRn :: Rn a -> RnEnv -> KZC a
runRn m = runReaderT (unRn m)

class EnsureUniq a where
    ensureUniq :: a -> Rn a

instance EnsureUniq TyVar where
    ensureUniq alpha = do
        ins <- inscope alpha
        if ins then uniquify alpha else return alpha
      where
        inscope :: TyVar -> Rn Bool
        inscope alpha = asks (Map.member alpha . tyVars)

instance EnsureUniq Var where
    ensureUniq v = do
        ins <- inscope v
        if ins then uniquify v else return v
      where
        inscope :: Var -> Rn Bool
        inscope v = do
            member_vars <- asks (Map.member v . vars)
            if member_vars
               then return True
               else asks (Map.member v . compVars)

extendTyVars :: Doc -> [TyVar] -> Rn a -> Rn a
extendTyVars desc alphas m = do
    checkDuplicates desc alphas
    alphas' <- mapM ensureUniq alphas
    extendEnv tyVars (\env x -> env { tyVars = x }) (alphas `zip` alphas') m

lookupTyVar :: TyVar -> Rn TyVar
lookupTyVar alpha =
    lookupEnv tyVars onerr alpha
  where
    onerr = faildoc $ text "Type variable" <+> ppr alpha <+> text "not in scope"

extendVars :: Doc -> [Var] -> Rn a -> Rn a
extendVars desc vs m = do
    checkDuplicates desc vs
    vs' <- mapM ensureUniq vs
    extendEnv vars (\env x -> env { vars = x }) (vs `zip` vs') m

lookupVar :: Var -> Rn Var
lookupVar v =
    lookupEnv vars onerr v
  where
    onerr = faildoc $ text "Variable" <+> ppr v <+> text "not in scope"

extendCompVars :: Doc -> [Var] -> Rn a -> Rn a
extendCompVars desc vs m = do
    checkDuplicates desc vs
    vs' <- mapM ensureUniq vs
    extendEnv compVars (\env x -> env { compVars = x }) (vs `zip` vs') m

lookupMaybeCompVar :: Var -> Rn Var
lookupMaybeCompVar v = do
    incs     <- asks compScope
    maybe_v' <- if incs
                then asks (Map.lookup v . compVars)
                else asks (Map.lookup v . vars)
    case maybe_v' of
      Just v' -> return v'
      Nothing -> do maybe_v' <- asks (Map.lookup v . vars)
                    case maybe_v' of
                      Nothing -> onerr
                      Just v' -> return v'
  where
    onerr = faildoc $ text "Variable" <+> ppr v <+> text "not in scope"

inCompScope :: Rn a -> Rn a
inCompScope = local $ \env -> env { compScope = True }

inPureScope :: Rn a -> Rn a
inPureScope = local $ \env -> env { compScope = False }
