{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- |
-- Module      :  KZC.Optimize.Eval.Monad
-- Copyright   :  (c) 2015-2016 Drexel University
-- License     :  BSD-style
-- Maintainer  :  mainland@cs.drexel.edu

module KZC.Optimize.Eval.Monad (
    EvalM
  ) where

import Control.Applicative (Applicative)
import Control.Monad.Reader (ReaderT(..))
import Control.Monad.State (StateT(..))

import KZC.Monad
import KZC.Uniq

data EvalEnv

data EvalState

newtype EvalM a = EvalM { unEvalM :: ReaderT EvalEnv (StateT EvalState KZC) a }

instance Functor EvalM where
instance Applicative EvalM where
instance Monad EvalM where
instance MonadUnique EvalM where