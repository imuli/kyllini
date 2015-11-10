{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      :  KZC.Auto.Comp
-- Copyright   :  (c) 2015 Drexel University
-- License     :  BSD-style
-- Maintainer  :  mainland@cs.drexel.edu

module KZC.Auto.Comp (
    varC,
    callC,
    ifC,
    ifC',
    letC,
    letC',
    liftC,
    returnC,
    bindC,
    bindC',
    gotoC,
    repeatC,
    takeC,
    takesC,
    emitC,
    emitsC,
    parC,

    mapCompLabels,
    uniquifyCompLabels
  ) where

import Control.Applicative (Applicative, (<$>), (<*>), pure)
import Control.Monad.Reader
import Data.Loc
import Data.Map (Map)
import qualified Data.Map as Map
import Text.PrettyPrint.Mainland

import KZC.Auto.Syntax
import KZC.Label
import KZC.Uniq

varC :: (Located a, MonadUnique m)
     => Var -> a -> m LComp
varC v a = do
    l <- genLabel "vark"
    return $ Comp [VarC l v (srclocOf a)]

callC :: (Located a, MonadUnique m)
      => Var -> [Iota] -> [Exp] -> a -> m LComp
callC f is es a = do
    l <- genLabel "callk"
    return $ Comp [CallC l f is es (srclocOf a)]

ifC :: (Located a, MonadUnique m)
    => Exp -> LComp -> LComp -> a -> m LComp
ifC e thenc elsec a = do
    l <- genLabel "ifk"
    return $ ifC' l e thenc elsec a

ifC' :: Located a
     => Label -> Exp -> LComp -> LComp -> a -> LComp
ifC' l e thenc elsec a = Comp [IfC l e thenc elsec (srclocOf a)]

letC :: (Located a, MonadUnique m)
     => LocalDecl -> a -> m LComp
letC decl a = do
    l <- genLabel "letk"
    return $ Comp [LetC l decl (srclocOf a)]

letC' :: Located a
      => Label -> LocalDecl -> a -> LComp
letC' l decl a = Comp [LetC l decl (srclocOf a)]

liftC :: (Located a, MonadUnique m)
      => Exp -> a -> m LComp
liftC e a = do
    l <- genLabel "liftk"
    return $ Comp [LiftC l e (srclocOf a)]

returnC :: (Located a, MonadUnique m)
        => Exp -> a -> m LComp
returnC e a = do
    l <- genLabel "returnk"
    return $ Comp [ReturnC l e (srclocOf a)]

bindC :: (Located a, MonadUnique m)
      => BindVar -> a -> m LComp
bindC bv a = do
    l <- genLabel "bindk"
    return $ Comp [BindC l bv (srclocOf a)]

bindC' :: Located a
       => Label -> BindVar -> a -> LComp
bindC' l bv a = Comp [BindC l bv (srclocOf a)]

gotoC :: (Located a, MonadUnique m)
      => Label -> a -> m LComp
gotoC l a = return $ Comp [GotoC l (srclocOf a)]

repeatC :: (Located a, MonadUnique m)
        => Label -> a -> m LComp
repeatC l a = return $ Comp [RepeatC l (srclocOf a)]

takeC :: (Located a, MonadUnique m)
      => Type -> a -> m LComp
takeC tau a = do
    l <- genLabel "takek"
    return $ Comp [TakeC l tau (srclocOf a)]

takesC :: (Located a, MonadUnique m)
       => Int -> Type -> a -> m LComp
takesC i tau a = do
    l <- genLabel "takesk"
    return $ Comp [TakesC l i tau (srclocOf a)]

emitC :: (Located a, MonadUnique m)
      => Exp -> a -> m LComp
emitC e a = do
    l <- genLabel "emitk"
    return $ Comp [EmitC l e (srclocOf a)]

emitsC :: (Located a, MonadUnique m)
       => Exp -> a -> m LComp
emitsC e a = do
    l <- genLabel "emitk"
    return $ Comp [EmitsC l e (srclocOf a)]

parC :: (Located a, MonadUnique m)
     => PipelineAnn -> Type -> LComp -> LComp -> a -> m LComp
parC ann tau c1 c2 a =
    return $ Comp [ParC ann tau c1 c2 (srclocOf a)]

type M l1 l2 m a = ReaderT (Map l1 l2) m a

mapCompLabels :: forall l1 l2 m . (Applicative m, MonadUnique m, IsLabel l1)
              => (l1 -> m l2) -> Comp l1 -> m (Comp l2)
mapCompLabels f comp =
    runReaderT (mlComp comp) Map.empty
  where
    mlComp :: Comp l1 -> M l1 l2 m (Comp l2)
    mlComp (Comp steps) = Comp <$> mlSteps steps

    mlSteps :: [Step l1] -> M l1 l2 m [Step l2]
    mlSteps [] =
        return []

    mlSteps (VarC l v s : steps) =
        ml l $ \l' ->
        (:) <$> pure (VarC l' v s) <*> mlSteps steps

    mlSteps (CallC l v iotas es s : steps) =
        ml l $ \l' ->
        (:) <$> pure (CallC l' v iotas es s) <*> mlSteps steps

    mlSteps (IfC l e c1 c2 s : steps) =
        ml l $ \l' -> do
        c1' <- mlComp c1
        c2' <- mlComp c2
        (:) <$> pure (IfC l' e c1' c2' s) <*> mlSteps steps

    mlSteps (LetC l decl s : steps) =
        ml l $ \l' ->
        (:) <$> pure (LetC l' decl s) <*> mlSteps steps

    mlSteps (LiftC l e s : steps) =
        ml l $ \l' ->
        (:) <$> pure (LiftC l' e s) <*> mlSteps steps

    mlSteps (ReturnC l e s : steps) =
        ml l $ \l' ->
        (:) <$> pure (ReturnC l' e s) <*> mlSteps steps

    mlSteps (BindC l bv s : steps) =
        ml l $ \l' ->
        (:) <$> pure (BindC l' bv s) <*> mlSteps steps

    mlSteps (GotoC l s : steps) = do
        (:) <$> (GotoC <$> lookupLabel l <*> pure s) <*> mlSteps steps

    mlSteps (RepeatC l s : steps) = do
        (:) <$> (RepeatC <$> lookupLabel l <*> pure s) <*> mlSteps steps

    mlSteps (TakeC l tau s : steps) =
        ml l $ \l' ->
        (:) <$> pure (TakeC l' tau s) <*> mlSteps steps

    mlSteps (TakesC l i tau s : steps) =
        ml l $ \l' ->
        (:) <$> pure (TakesC l' i tau s) <*> mlSteps steps

    mlSteps (EmitC l tau s : steps) =
        ml l $ \l' ->
        (:) <$> pure (EmitC l' tau s) <*> mlSteps steps

    mlSteps (EmitsC l tau s : steps) =
        ml l $ \l' ->
        (:) <$> pure (EmitsC l' tau s) <*> mlSteps steps

    mlSteps (ParC ann tau c1 c2 s : steps) = do
        step'  <- ParC ann tau <$> mlComp c1 <*> mlComp c2 <*> pure s
        steps' <- mlSteps steps
        return $ step' : steps'

    lookupLabel :: l1 -> M l1 l2 m l2
    lookupLabel l = do
        theta  <- ask
        case Map.lookup l theta of
          Just l' -> return l'
          Nothing -> faildoc $ text "Label" <+> ppr l <+> text "not in scope"

    ml :: l1 -> (l2 -> M l1 l2 m a) -> M l1 l2 m a
    ml l k = do
        l' <- lift $ f l
        local (\env -> Map.insert l l' env) $ k l'

uniquifyCompLabels :: forall m . (Applicative m, MonadUnique m)
                   => Comp Label -> m (Comp Label)
uniquifyCompLabels comp = mapCompLabels uniquifyLabel comp