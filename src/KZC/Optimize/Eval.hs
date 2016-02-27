{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      :  KZC.Optimize.Eval
-- Copyright   :  (c) 2015-2016 Drexel University
-- License     :  BSD-style
-- Maintainer  :  mainland@cs.drexel.edu

module KZC.Optimize.Eval (
    EvalM,
    evalEvalM,

    evalProgram,
    toExp
  ) where

import Control.Applicative ((<$>), (<*>), pure)
import Control.Monad (filterM)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Maybe (MaybeT(..))
import Data.Bits
import Data.Loc
import qualified Data.Map as Map
import Data.Monoid
import Data.Ratio (numerator)
import Data.Set (Set)
import qualified Data.Set as Set
import Text.PrettyPrint.Mainland

import KZC.Auto.Comp
import KZC.Auto.Lint
import KZC.Auto.Smart
import KZC.Auto.Syntax
import KZC.Error
import KZC.Optimize.Eval.Monad
import qualified KZC.Optimize.Eval.PArray as P
import KZC.Optimize.Eval.Val
import KZC.Summary
import KZC.Util.SetLike
import KZC.Vars

evalProgram :: LProgram -> EvalM LProgram
evalProgram (Program decls comp tau) =
  evalDecls decls $ \mkDecls ->
  inSTScope tau $
  inLocalScope $
  withLocContext comp (text "In definition of main") $ do
  val         <- evalComp comp
  (h', comp') <- case val of
                   CompReturnV {}  -> do h'    <- getHeap
                                         comp' <- toComp val
                                         return (h', comp')
                   CompV h' steps' -> return (h', Comp steps')
                   _               -> faildoc $ text "Computation did not return CompReturnV or CompV."
  decls' <- mkDecls h'
  return $ Program decls' comp' tau

evalDecls :: [LDecl] -> ((Heap -> EvalM [LDecl]) -> EvalM a) -> EvalM a
evalDecls [] k =
    k $ \_h -> return []

evalDecls (decl:decls) k =
    evalDecl  decl  $ \mkDecl' ->
    evalDecls decls $ \mkDecls' ->
    k $ \h -> (:) <$> mkDecl' h <*> mkDecls' h

evalDecl :: forall a . LDecl -> ((Heap -> EvalM LDecl) -> EvalM a) -> EvalM a
evalDecl (LetD decl s) k =
    evalLocalDecl decl go
  where
    go :: LocalLetVal -> EvalM a
    go (DeclVal decl') =
        k $ \_h -> return $ LetD decl' s

    go (HeapDeclVal mkDecl) =
        k $ \h -> LetD <$> mkDecl h <*> pure s

evalDecl (LetFunD f ivs vbs tau_ret e l) k = do
    extendVars [(bVar f, tau)] $ do
    theta <- askSubst
    withUniqBoundVar f $ \f' -> do
    withUniqVars vs $ \vs' -> do
    e' <- killHeap $
          extendIVars (ivs `zip` repeat IotaK) $
          extendVars vbs $
          extendUnknownVarBinds vbs $
          inSTScope tau_ret $
          inLocalScope $
          withSummaryContext e $
          toExp <$> evalExp e
    extendVarBinds [(bVar f', FunClosV theta ivs (vs' `zip` taus) tau_ret eval)] $ do
    k $ const . return $ LetFunD f' ivs (vs' `zip` taus) tau_ret e' l
  where
    tau :: Type
    tau = FunT ivs taus tau_ret l

    vs :: [Var]
    taus :: [Type]
    (vs, taus) = unzip vbs

    eval :: EvalM (Val Exp)
    eval =
        extendIVars (ivs `zip` repeat IotaK) $
        extendVars vbs $
        withInstantiatedTyVars tau_ret $
        withSummaryContext e $
        evalExp e

evalDecl (LetExtFunD f iotas vbs tau_ret l) k =
    extendVars [(bVar f, tau)] $
    extendVarBinds [(bVar f, UnknownV)] $
    k $ const . return $ LetExtFunD f iotas vbs tau_ret l
  where
    tau :: Type
    tau = FunT iotas (map snd vbs) tau_ret l

evalDecl (LetStructD s flds l) k =
    extendStructs [StructDef s flds l] $
    k $ const . return $ LetStructD s flds l

evalDecl (LetCompD v tau comp s) k =
    extendVars [(bVar v, tau)] $ do
    theta <- askSubst
    withUniqBoundVar v $ \v' -> do
    comp' <- killHeap $
             inSTScope tau $
             inLocalScope $
             evalComp comp >>= toComp
    extendCVarBinds [(bVar v', CompClosV theta tau eval)] $ do
    k $ const . return $ LetCompD v' tau comp' s
  where
    eval :: EvalM (Val LComp)
    eval =
        withInstantiatedTyVars tau $
        withSummaryContext comp $
        uniquifyCompLabels comp >>= evalComp

evalDecl (LetFunCompD f ivs vbs tau_ret comp l) k =
    extendVars [(bVar f, tau)] $ do
    theta <- askSubst
    withUniqBoundVar f $ \f' -> do
    withUniqVars vs $ \vs' -> do
    comp' <- killHeap $
             extendIVars (ivs `zip` repeat IotaK) $
             extendVars vbs $
             extendUnknownVarBinds vbs $
             inSTScope tau_ret $
             inLocalScope $
             evalComp comp >>= toComp
    extendCVarBinds [(bVar f', FunCompClosV theta ivs (vs' `zip` taus) tau_ret eval)] $ do
    k $ const . return $ LetFunCompD f' ivs (vs' `zip` taus) tau_ret comp' l
  where
    tau :: Type
    tau = FunT ivs taus tau_ret l

    vs :: [Var]
    taus :: [Type]
    (vs, taus) = unzip vbs

    eval :: EvalM (Val LComp)
    eval =
        withSummaryContext comp $
        extendIVars (ivs `zip` repeat IotaK) $
        extendVars vbs $
        withInstantiatedTyVars tau_ret $
        uniquifyCompLabels comp >>= evalComp

data LocalLetVal -- | Local declaration is pure and produces a declaration
                 = DeclVal LocalDecl
                 -- | Local declaration requires a heap so it can push the heap
                 -- through the declaration.
                 | HeapDeclVal (Heap -> EvalM LocalDecl)

evalLocalDecl :: forall a . LocalDecl -> (LocalLetVal -> EvalM a) -> EvalM a
evalLocalDecl (LetLD v tau e1 s1) k =
    extendVars [(bVar v, tau)] $ do
    -- Bind v to the value of e2
    val1 <- withSummaryContext e1 $ evalExp e1
    withUniqBoundVar v $ \v' -> do
    extendVarBinds [(bVar v', val1)] $ do
    tau' <- simplType tau
    k $ DeclVal $ LetLD v' tau' (toExp val1) s1

evalLocalDecl decl@(LetRefLD v tau maybe_e1 s1) k =
    extendVars [(bVar v, refT tau)] $ do
    withUniqBoundVar v $ \v' -> do
    tau' <- simplType tau
    -- Allocate heap storage for v and initialize it
    ptr  <- newVarPtr
    val1 <- case maybe_e1 of
              Nothing -> maybe UnknownV id <$> defaultValue tau'
              Just e1 -> withSummaryContext e1 $ evalExp e1
    writeVarPtr ptr val1
    extendVarBinds [(bVar v', RefV (VarR (bVar v') ptr))] $ do
    k $ HeapDeclVal $ \h ->
        withSummaryContext decl $ do
        tau'      <- simplType tau
        maybe_e1' <- mkInit h ptr val1
        return $ LetRefLD v' tau' maybe_e1' s1
  where
    mkInit :: Heap -> VarPtr -> Val Exp -> EvalM (Maybe Exp)
    mkInit h ptr dflt = do
        val      <- heapLookup h ptr
        let val' =  if isKnown val then val else dflt
        case val' of
          UnknownV                -> return Nothing
          _ | isDefaultValue val' -> return Nothing
            | otherwise           -> return $ Just (toExp val')

evalComp :: LComp -> EvalM (Val LComp)
evalComp (Comp steps) = evalSteps steps
  where
    evalSteps :: [LStep] -> EvalM (Val LComp)
    evalSteps [] =
        faildoc $ text "Cannot evaluate empty sequence of steps"

    evalSteps [step] =
        evalStep step

    evalSteps (LetC l decl s : steps) = do
        evalLocalDecl decl go
      where
        go :: LocalLetVal -> EvalM (Val LComp)
        go (DeclVal decl') = do
            val <- evalSteps steps
            case val of
              CompV h steps' -> partial $ CompV h $ LetC l decl' s : steps'
              _              -> return val

        go (HeapDeclVal k) = do
            val <- evalSteps steps
            case val of
              CompV h steps' -> do decl' <- k h
                                   partial $ CompV h $ LetC l decl' s : steps'
              _              -> return val

    evalSteps (step:steps) = do
        val <- evalStep step
        case val of
          CompReturnV {} -> evalBind step val steps
          CompV h steps1 -> do steps2 <- evalFullBind steps
                               return $ CompV h (steps1 ++ steps2)
          _              -> faildoc $ text "Step did not return CompReturnV or CompV."

    evalBind :: LStep -> Val LComp -> [LStep] -> EvalM (Val LComp)
    evalBind _step (CompReturnV val1) (BindC l wv tau s : k) =
        extendWildVars [(wv, tau)] $
        withUniqWildVar wv $ \wv' -> do
        extendWildVarBinds [(wv', val1)] $ do
        val <- evalSteps k
        case val of
          CompReturnV {}  -> return val
          CompV h steps2' -> do tau'    <- simplType tau
                                steps1' <- returnC (toExp val1)
                                partial $ CompV h $ unComp steps1' ++ BindC l wv' tau' s : steps2'
          _               -> faildoc $ text "Steps did not return CompReturnV or CompV."

    evalBind _step (CompReturnV _val1) k =
        evalSteps k

    evalBind _step (CompV h1 steps1') (BindC l wv tau s : k) =
        extendWildVars [(wv, tau)] $ do
        withUniqWildVar wv $ \wv' -> do
        killVars steps1'
        tau'    <- simplType tau
        steps2' <- extendWildVarBinds [(wv', UnknownV)] $
                   evalFullSteps k
        partial $ CompV h1 $ steps1' ++ BindC l wv' tau' s : steps2'

    evalBind _step (CompV h1 steps1') k = do
        killVars steps1'
        steps2' <- evalFullSteps k
        partial $ CompV h1 $ steps1' ++ steps2'

    evalBind step _ _ =
        withSummaryContext step $
        faildoc $ text "Command did not return CmdV or ReturnV."

    evalFullBind :: [LStep] -> EvalM [LStep]
    evalFullBind (BindC l wv tau s : steps) =
        extendWildVars [(wv, tau)] $
        withUniqWildVar wv $ \wv' -> do
        tau'   <- simplType tau
        steps' <- extendWildVarBinds [(wv, UnknownV)] $
                  evalFullSteps steps
        return $ BindC l wv' tau' s : steps'

    evalFullBind steps =
        evalFullSteps steps

evalStep :: LStep -> EvalM (Val LComp)
evalStep (VarC _ v _) =
    lookupCVarBind v >>= go
  where
    go :: Val a -> EvalM (Val LComp)
    go (CompClosV theta _tau k) =
        withSubst theta $
        k

    go val@(CompVarV {}) =
        return val

    go _ =
        faildoc $
        text "Variable" <+> ppr v <+>
        text "is not a computation, but we are trying to call it!"

evalStep step@(CallC _ f iotas args _) =
    withSummaryContext step $ do
    maybe_f' <- lookupSubst f
    v_f      <- case maybe_f' of
                  Nothing -> lookupCVarBind f
                  Just f' -> lookupCVarBind f'
    iotas'  <- mapM simplIota iotas
    v_args  <- mapM evalArg args
    go v_f iotas' v_args
  where
    go :: Val a -> [Iota] -> [ArgVal] -> EvalM (Val LComp)
    go (FunCompClosV theta ivs vbs _tau_ret k) iotas' v_args =
        withSubst theta $
        withUniqVars vs $ \vs' -> do
        extendIVarSubst (ivs `zip` iotas') $ do
        extendArgBinds  (vs' `zip` v_args) $ do
        taus' <- mapM simplType taus
        k >>= wrapLetArgs vs' taus'
      where
        vs :: [Var]
        taus :: [Type]
        (vs, taus) = unzip vbs

        -- If @val@ uses any of the function's parameter bindings, we need to
        -- keep them around. This is exactly what we need to do in the @CallE@
        -- case, but here we need to add bindings to a computation rather than
        -- to an expression.
        wrapLetArgs :: [Var] -> [Type] -> Val LComp -> EvalM (Val LComp)
        wrapLetArgs vs' taus' val = do
            bs <- filterM isFree (zip3 vs' taus' v_args)
            if null bs
              then return val
              else transformCompVal (letBinds bs) val
          where
            letBinds :: [(Var, Type, ArgVal)] -> LComp -> EvalM LComp
            letBinds bs (Comp steps) = do
              bindsSteps <- mapM letBind bs
              return $ Comp $ concat bindsSteps ++ steps

            letBind :: (Var, Type, ArgVal) -> EvalM [LStep]
            letBind (_v, RefT {}, _e1)      = return []
            letBind (v,  tau,     ExpAV e1) = unComp <$> letC v tau (toExp e1)
            letBind (_v, _tau,    _e1)      = return []

            isFree :: (Var, Type, ArgVal) -> EvalM Bool
            isFree (v, _, _) = do
                comp <- toComp val
                return $ v `member` (fvs comp :: Set Var)

    go _val _iotas' _v_es = do
      faildoc $ text "Cannot call computation function" <+> ppr f

    evalArg :: LArg -> EvalM ArgVal
    evalArg (ExpA e)  = ExpAV <$> evalExp e
    evalArg (CompA c) = do tau   <- inferComp c
                           theta <- askSubst
                           return $ CompAV $ CompClosV theta tau (evalComp c)

    extendArgBinds :: [(Var, ArgVal)] -> EvalM a -> EvalM a
    extendArgBinds []                   m = m
    extendArgBinds ((v, ExpAV e):args)  m = extendVarBinds [(v, e)] $
                                            extendArgBinds args m
    extendArgBinds ((v, CompAV c):args) m = extendCVarBinds [(v, c)] $
                                            extendArgBinds args m

evalStep (IfC l e1 c2 c3 s) = do
    h <- getHeap
    evalExp e1 >>= evalIfBody h
  where
    -- Note that @e1@ is pure, so we don't have to worry about it changing the
    -- heap.
    evalIfBody :: Heap -> Val Exp -> EvalM (Val LComp)
    evalIfBody h val
        | isTrue  val = evalComp c2
        | isFalse val = evalComp c3
        | otherwise   = do c2' <- savingHeap $ evalFullSteps $ unComp c2
                           c3' <- savingHeap $ evalFullSteps $ unComp c3
                           killVars c2'
                           killVars c3'
                           partial $ CompV h [IfC l (toExp val) (Comp c2') (Comp c3') s]

evalStep (LetC {}) =
    panicdoc $ text "evalStep: saw LetC"

evalStep (WhileC _ e c _) =
    evalWhile e c

evalStep (ForC _ ann v tau e1 e2 c _) =
    evalFor ann v tau e1 e2 c

evalStep step@(LiftC l e s) = do
    val <- withSummaryContext e $ evalExp e
    case val of
      ReturnV val' -> return $ CompReturnV val'
      CmdV h e'    -> partial $ CompV h [LiftC l e' s]
      _            -> withSummaryContext step $
                      faildoc $ text "Command did not return CmdV or ReturnV."

evalStep (ReturnC l e s) = do
    val <- evalExp e
    case val of
      ExpV e' -> partialComp $ Comp [ReturnC l e' s]
      _       -> return $ CompReturnV val

evalStep (BindC {}) =
    panicdoc $ text "evalStep: saw BindC"

evalStep (TakeC l tau s) = do
    tau' <- simplType tau
    partialComp $ Comp [TakeC l tau' s]

evalStep (TakesC l n tau s) = do
    tau' <- simplType tau
    partialComp $ Comp [TakesC l n tau' s]

evalStep (EmitC l e s) = do
    val <- evalExp e
    partialComp $ Comp [EmitC l (toExp val) s]

evalStep (EmitsC l e s) = do
    val <- evalExp e
    partialComp $ Comp [EmitsC l (toExp val) s]

evalStep (RepeatC l ann c s) = do
    h <- getHeap
    killVars c
    val    <- savingHeap $
              withSummaryContext c $
              evalComp c
    steps' <- toSteps val
    partial $ CompV h $ [RepeatC l ann (Comp steps') s]

evalStep (ParC ann tau c1 c2 s) = do
    h      <- getHeap
    val1   <- withSummaryContext c1 $ evalComp c1
    val2   <- withSummaryContext c2 $ evalComp c2
    steps1 <- toSteps val1
    steps2 <- toSteps val2
    partial $ CompV h $ [ParC ann tau (Comp steps1) (Comp steps2) s]

evalStep (LoopC {}) =
    panicdoc $ text "evalStep: saw LoopC"

-- | Fully evaluate a sequence of steps in the current heap, returning a
-- sequence of steps representing all changes to the heap.
evalFullSteps :: [LStep] -> EvalM [LStep]
evalFullSteps steps = do
    h            <- getHeap
    val          <- evalComp (Comp steps)
    (h', steps') <- case val of
                      CompReturnV {}  -> do h'     <- getHeap
                                            steps' <- toSteps val
                                            return (h', steps')
                      CompV h' steps' -> return (h', steps')
                      _               -> faildoc $ text "Computation did not return CompReturnV or CompV."
    unComp <$> diffHeapComp h h' (Comp steps')

evalFullComp :: LComp -> EvalM LComp
evalFullComp comp = Comp <$> evalFullSteps (unComp comp)

evalConst :: Const -> EvalM (Val Exp)
evalConst UnitC              = return UnitV
evalConst (BoolC f)          = return $ BoolV f
evalConst (FixC sc s w bp r) = return $ FixV sc s w bp r
evalConst (FloatC fp r)      = return $ FloatV fp r
evalConst (StringC s)        = return $ StringV s
evalConst c@(ArrayC cs)      = do (_, tau)   <- inferConst noLoc c >>= checkArrT
                                  vals       <- mapM evalConst cs
                                  maybe_dflt <- defaultValue tau
                                  case maybe_dflt of
                                    Nothing   -> partialExp $ arrayE (map toExp vals)
                                    Just dflt -> return $ ArrayV $ P.fromList dflt vals

evalConst (StructC s flds) = do
    vals <- mapM evalConst cs
    return $ StructV s (Map.fromList (fs `zip` vals))
  where
    fs :: [Field]
    cs :: [Const]
    (fs, cs) = unzip  flds

evalExp :: Exp -> EvalM (Val Exp)
evalExp (ConstE c _) =
    evalConst c

evalExp (VarE v _) = do
    v' <- maybe v id <$> lookupSubst v
    lookupVarBind v'

evalExp (UnopE op e s) = do
    val <- evalExp e
    unop op val
  where
    unop :: Unop -> Val Exp -> EvalM (Val Exp)
    unop Lnot val =
        maybePartialVal $ liftBool op not val

    unop Bnot val =
        maybePartialVal $ liftBits op complement val

    unop Neg val =
        maybePartialVal $ negate val

    unop (Cast tau) (FixV _ _ _ (BP 0) r) | isBitT tau =
        return $ FixV I U (W 1) (BP 0) (if r == 0 then 0 else 1)

    unop (Cast (FixT I U (W w) (BP 0) _)) (FixV I _ _ (BP 0) r) | r <= 2^w - 1 =
        return $ FixV I U (W w) (BP 0) r

    unop (Cast (FixT I S (W w) (BP 0) _)) (FixV I _ _ (BP 0) r) | r <= 2^(w-1) - 1 && r >= -(2^(w-1)) =
        return $ FixV I S (W w) (BP 0) r

    unop (Cast (FixT I s w (BP 0) _)) (FloatV _ r) =
        return $ FixV I s w (BP 0) (fromIntegral (truncate r :: Integer))

    unop (Cast (FloatT fp _)) (FixV I _ _ (BP 0) r) =
        return $ FloatV fp r

    unop Len val = do
        (iota, _) <- inferExp e >>= checkArrT
        psi       <- askIVarSubst
        case subst psi mempty iota of
          ConstI n _ -> evalConst $ intC n
          _ -> partialExp $ UnopE op (toExp val) s

    unop op val =
        partialExp $ UnopE op (toExp val) s

evalExp (BinopE op e1 e2 s) = do
    val1 <- evalExp e1
    val2 <- evalExp e2
    binop op val1 val2
  where
    binop :: Binop -> Val Exp -> Val Exp -> EvalM (Val Exp)
    binop Lt val1 val2 =
        maybePartialVal $ liftOrd op (<) val1 val2

    binop Le val1 val2 =
        maybePartialVal $ liftOrd op (<=) val1 val2

    binop Eq val1 val2 =
        maybePartialVal $ liftEq op (==) val1 val2

    binop Ge val1 val2 =
        maybePartialVal $ liftOrd op (>=) val1 val2

    binop Gt val1 val2 =
        maybePartialVal $ liftOrd op (>) val1 val2

    binop Ne val1 val2 =
        maybePartialVal $ liftEq op (/=) val1 val2

    binop Land val1 val2
        | isTrue  val1 = maybePartialVal val2
        | isFalse val1 = return $ BoolV False
        | otherwise    = maybePartialVal $ liftBool2 op (&&) val1 val2

    binop Lor val1 val2
        | isTrue  val1 = return $ BoolV True
        | isFalse val1 = maybePartialVal val2
        | otherwise    = maybePartialVal $ liftBool2 op (||) val1 val2

    binop Band val1 val2 =
        maybePartialVal $ liftBits2 op (.&.) val1 val2

    binop Bor val1 val2
        | isZero val1 = maybePartialVal val2
        | isZero val2 = maybePartialVal val1
        | otherwise   = maybePartialVal $ liftBits2 op (.|.) val1 val2

    binop Bxor val1 val2
        | isZero val1 = maybePartialVal val2
        | isZero val2 = maybePartialVal val1
        | otherwise   = maybePartialVal $ liftBits2 op xor val1 val2

    binop LshL val1 val2 =
        maybePartialVal $ liftShift op shiftL val1 val2

    binop AshR val1 val2 =
        maybePartialVal $ liftShift op shiftR val1 val2

    binop Add val1 val2 = maybePartialVal $ val1 + val2

    binop Sub val1 val2 = maybePartialVal $ val1 - val2

    binop Mul val1 val2 = maybePartialVal $ val1 * val2

    binop Div (FixV I s w (BP 0) r1) (FixV _ _ _ _ r2) =
        return $ FixV I s w (BP 0) (fromIntegral (numerator r1 `quot` numerator r2))

    binop Div (FloatV fp x) (FloatV _ y) =
        return $ FloatV fp (x / y)

    binop Rem (FixV I s w (BP 0) r1) (FixV _ _ _ _ r2) =
        return $ FixV I s w (BP 0) (fromIntegral (numerator r1 `rem` numerator r2))

    binop op val1 val2 =
        partialExp $ BinopE op (toExp val1) (toExp val2) s

evalExp e@(IfE e1 e2 e3 s) = do
    tau <- inferExp e
    h   <- getHeap
    evalExp e1 >>= evalIfExp tau h
  where
    -- Note that @e1@ is pure, so we don't have to worry about it changing the
    -- heap.
    evalIfExp :: Type -> Heap -> Val Exp -> EvalM (Val Exp)
    evalIfExp tau h val
        | isTrue  val = evalExp e2
        | isFalse val = evalExp e3
        | isPureT tau = do val2 <- evalExp e2
                           val3 <- evalExp e3
                           partial $ ExpV $ IfE (toExp val) (toExp val2) (toExp val3) s
        | otherwise   = do e2' <- savingHeap $ evalFullCmd e2
                           e3' <- savingHeap $ evalFullCmd e3
                           killVars e2'
                           killVars e3'
                           partial $ CmdV h $ IfE (toExp val) e2' e3' s

evalExp (LetE decl e2 s2) =
    evalLocalDecl decl go
  where
    go :: LocalLetVal -> EvalM (Val Exp)
    go (DeclVal decl) = do
        val2 <- evalExp e2
        case val2 of
          ExpV e2'   -> partial $ ExpV   $ LetE decl e2' s2
          CmdV h e2' -> partial $ CmdV h $ LetE decl e2' s2
          _          -> wrapLet decl val2

    go (HeapDeclVal k) = do
        val2 <- evalExp e2
        case val2 of
          ExpV e2'   -> do decl <- getHeap >>= k
                           partial $ ExpV   $ LetE decl e2' s2
          CmdV h e2' -> do decl <- k h
                           partial $ CmdV h $ LetE decl e2' s2
          _          -> do decl <- getHeap >>= k
                           wrapLet decl val2

    wrapLet :: LocalDecl -> Val Exp -> EvalM (Val Exp)
    wrapLet decl val2
        | v `Set.member` fvs e2 = partialExp $ LetE decl e2 s2
        | otherwise             = return val2
      where
        e2 :: Exp
        e2 = toExp val2

        v :: Var
        [v] = Set.toList (binders decl)

evalExp e@(CallE f iotas es s) = do
    maybe_f' <- lookupSubst f
    v_f      <- case maybe_f' of
                  Nothing -> lookupVarBind f
                  Just f' -> lookupVarBind f'
    iotas'  <- mapM simplIota iotas
    v_es    <- mapM evalExp es
    tau     <- inferExp e
    go tau v_f iotas' v_es
  where
    go :: Type -> Val Exp -> [Iota] -> [Val Exp] -> EvalM (Val Exp)
    go _tau (FunClosV theta ivs vbs _tau_ret k) iotas' v_es =
        withSubst theta $
        withUniqVars vs $ \vs' -> do
        extendIVarSubst (ivs `zip` iotas') $ do
        extendVarBinds  (vs' `zip` v_es) $ do
        taus' <- mapM simplType taus
        k >>= wrapLetArgs vs' taus'
      where
        vs :: [Var]
        taus :: [Type]
        (vs, taus) = unzip vbs

        -- If @val@ uses any of the function's parameter bindings, we need to
        -- keep them around. This can happen if we decide not to inline a
        -- variable, e.g., if the variable is bound to an array constant.
        wrapLetArgs :: [Var] -> [Type] -> Val Exp -> EvalM (Val Exp)
        wrapLetArgs vs' taus' val =
            -- We must be careful here not to apply transformExpVal if the list
            -- of free variables is null because @transformExpVal id@ is not the
            -- identify function!
            case filter isFree (zip3 vs' taus' v_es) of
              [] -> return val
              bs -> transformExpVal (letBinds bs) val
          where
            letBinds :: [(Var, Type, Val Exp)] -> Exp -> Exp
            letBinds bs e = foldr letBind e bs

            letBind :: (Var, Type, Val Exp) -> Exp -> Exp
            letBind (_v, RefT {}, _e1) e2 = e2
            letBind (v,  tau,      e1) e2 = letE v tau (toExp e1) e2

            isFree :: (Var, Type, Val Exp) -> Bool
            isFree (v, _, _) = v `member` (fvs (toExp val) :: Set Var)

    -- Note that the heap cannot change as the result of evaluating function
    -- arguments, so we can call 'partialCmd' here instead of saving the heap
    -- above and constructing a 'CmdV' from it manually.
    go tau (ExpV (VarE f' _)) iotas' v_es
       | isPureT tau = do killVars e
                          partialExp $ CallE f' iotas' (map toExp v_es) s
       | otherwise   = do killVars e
                          partialCmd $ CallE f' iotas' (map toExp v_es) s

    go _tau val _iotas' _v_es = do
      faildoc $ text "Cannot call function" <+> ppr val

evalExp (DerefE e s) =
    evalExp e >>= go
  where
    go :: Val Exp -> EvalM (Val Exp)
    go (RefV r) = do
        val <- readVarPtr (refVarPtr r)
        if isKnown val
          then ReturnV <$> refView r val
          else partialCmd $ DerefE (toExp r) s

    go val =
        partialCmd $ DerefE (toExp val) s

evalExp e@(AssignE e1 e2 s) = do
    val1 <- evalExp e1
    val2 <- evalExp e2
    go val1 val2
  where
    go :: Val Exp -> Val Exp -> EvalM (Val Exp)
    go (RefV r) val2 = do
        h         <- getHeap
        old       <- readVarPtr ptr
        maybe_new <- runMaybeT $ refUpdate r old val2
        case maybe_new of
          Just new | isValue new ->
              do writeVarPtr ptr new
                 return $ ReturnV UnitV
          _ ->
              do killVars e
                 partial $ CmdV h $ AssignE (toExp r) (toExp val2) s
      where
        ptr :: VarPtr
        ptr = refVarPtr r

    go val1 val2 =
        partialCmd $ AssignE (toExp val1) (toExp val2) s

evalExp (WhileE e1 e2 _) =
    evalWhile e1 e2

evalExp (ForE ann v tau e1 e2 e3 _) =
    evalFor ann v tau e1 e2 e3

evalExp e@(ArrayE es _) = do
    (_, tau)   <- inferExp e >>= checkArrT
    vals       <- mapM evalExp es
    maybe_dflt <- defaultValue tau
    case maybe_dflt of
      Nothing   -> partialExp $ arrayE (map toExp vals)
      Just dflt -> return $ ArrayV $ P.fromList dflt vals

evalExp (IdxE arr start len _) = do
    v_arr   <- evalExp arr
    v_start <- evalExp start
    v       <- evalIdx v_arr v_start len
    uninlineArrayConstant v arr v_arr v_start len
  where
    uninlineArrayConstant :: Val Exp -> Exp -> Val Exp -> Val Exp -> Maybe Int -> EvalM (Val Exp)
    uninlineArrayConstant v _ _ _ _ | isValue v =
        return v

    uninlineArrayConstant v@(RefV {}) _ _ _ _ =
        return v

    uninlineArrayConstant _ (VarE v _) arr@(ArrayV {}) v_start Nothing | isValue arr = do
        v' <- maybe v id <$> lookupSubst v
        return $ IdxV (ExpV $ varE v') v_start

    uninlineArrayConstant _ (VarE v _) arr@(ArrayV {}) v_start (Just len) | isValue arr = do
        v' <- maybe v id <$> lookupSubst v
        return $ SliceV (ExpV $ varE v') v_start len

    uninlineArrayConstant v _ _ _ _ =
        return v

evalExp (StructE s flds _) = do
    vals <- mapM evalExp es
    return $ StructV s (Map.fromList (fs `zip` vals))
  where
    fs :: [Field]
    es :: [Exp]
    (fs, es) = unzip  flds

evalExp (ProjE e f _) = do
    val <- evalExp e
    evalProj val f

evalExp (PrintE nl es s) = do
    vals <- mapM evalExp es
    partialCmd $ PrintE nl (map toExp vals) s

evalExp e@(ErrorE {}) =
    partialCmd e

evalExp (ReturnE _ e _) = do
    val <- evalExp e
    case val of
      ExpV e -> partialCmd $ returnE e
      _      -> return $ ReturnV val

evalExp (BindE wv tau e1 e2 s) = do
    val1 <- withSummaryContext e1 $ evalExp e1
    extendWildVars [(wv, tau)] $ do
    withUniqWildVar wv $ \wv' -> do
    tau' <- simplType tau
    case val1 of
      CmdV h1 e1'   -> do killVars e1'
                          e2'  <- extendWildVarBinds [(wv', UnknownV)] $
                                  evalFullCmd e2
                          partial $ CmdV h1 $ BindE wv' tau' e1' e2' s
      ReturnV val1' -> extendWildVarBinds [(wv', val1')] $
                       withSummaryContext e2 $
                       evalExp e2 >>= wrapBind wv' tau' val1'
      _             -> withSummaryContext e1 $
                       faildoc $ text "Command did not return CmdV or ReturnV."
  where
    -- If @val2@ uses the binding, we need to keep it around. This can happen if
    -- we decide not to inline a variable, e.g., if the variable is bound to an
    -- array constant.
    wrapBind :: WildVar -> Type -> Val Exp -> Val Exp -> EvalM (Val Exp)
    wrapBind (TameV bv) tau val1 val2 | v `Set.member` fvs e2 =
        partialCmd $ letE v tau e1 e2
      where
        v :: Var
        v = bVar bv

        e1, e2 :: Exp
        e1 = toExp val1
        e2 = toExp val2

    wrapBind _ _ _ val2 =
        return val2

evalExp (LutE e) =
    evalExp e

-- | Fully evaluate an expression, which must be an effectful command, in the
-- current heap, and return a single expression representing all changes to the
-- heap. We use this when we need to sequence two commands and the first command
-- produced a residual, meaning we can't push the prefix heap of the second
-- command past the first command.
evalFullCmd :: Exp -> EvalM Exp
evalFullCmd e =
    withSummaryContext e $ do
    h        <- getHeap
    val      <- evalExp e
    (h', e') <- case val of
                  ReturnV {} -> do h' <- getHeap
                                   return (h', toExp val)
                  CmdV h' e' -> return (h', e')
                  _          -> faildoc $ text "Command did not return CmdV or ReturnV." </> ppr val
    diffHeapExp h h' e'

refVarPtr :: Ref -> VarPtr
refVarPtr (VarR _ ptr) = ptr
refVarPtr (IdxR r _ _) = refVarPtr r
refVarPtr (ProjR r _)  = refVarPtr r

refView :: Ref -> Val Exp -> EvalM (Val Exp)
refView (VarR {})      val = return val
refView (IdxR r i len) val = do val' <- refView r val
                                evalIdx val' i len
refView (ProjR r f)    val = do val' <- refView r val
                                evalProj val' f

-- | Update a reference to an object given the old value of the entire object
-- and the new value of the pointed-to part.
refUpdate :: Ref -> Val Exp -> Val Exp -> MaybeT EvalM (Val Exp)
refUpdate (VarR {}) _ new =
    return new

refUpdate (IdxR r i len) old new = do
    old' <- lift $ refView r old
    go i len old' new
  where
    go :: Val Exp -> Maybe Int -> Val Exp -> Val Exp -> MaybeT EvalM (Val Exp)
    go (FixV I _ _ (BP 0) n) Nothing (ArrayV vs) new = do
        new' <- ArrayV <$> vs P.// [(start, new)]
        refUpdate r old new'
      where
        start :: Int
        start = fromIntegral (numerator n)

    go (FixV I _ _ (BP 0) n) (Just len) (ArrayV vs) (ArrayV vs') = do
        new' <- ArrayV <$> vs P.// ([start..start+len-1] `zip` P.toList vs')
        refUpdate r old new'
      where
        start :: Int
        start = fromIntegral (numerator n)

    go _ _ _ _ =
        fail "Cannot take slice of non-ArrayV"

refUpdate (ProjR r f) old new = do
    old' <- lift $ refView r old
    go f old' new
  where
    go :: Field -> Val Exp -> Val Exp -> MaybeT EvalM (Val Exp)
    go f (StructV s flds) new = do
        let new' = StructV s (Map.insert f new flds)
        refUpdate r old new'

    go _ _ _ =
        fail "Cannot project non-StructV"

class Eval a where
    eval :: a -> EvalM (Val a)

    returnUnit :: Val a

    residualWhile :: Exp -> a -> EvalM (Val a)

    -- | Construct a residual for loop. The loop bounds have already been
    -- residualized.
    residualFor :: UnrollAnn -> Var -> Type -> Exp -> Exp -> a -> EvalM (Val a)

instance Eval Exp where
    eval =
        evalExp

    returnUnit = ReturnV UnitV

    residualWhile e1 e2 =
        savingHeap $ do
        killVars e1
        killVars e2
        e1' <- evalFullCmd e1
        e2' <- evalFullCmd e2
        partialCmd $ whileE e1' e2'

    residualFor ann v tau e1 e2 e3 =
        savingHeap $
        extendVarBinds [(v, UnknownV)] $ do
        killVars e3
        e3' <- evalFullCmd e3
        partialCmd $ forE ann v tau e1 e2 e3'

instance Eval LComp where
    eval =
        evalComp

    returnUnit =
        CompReturnV UnitV

    residualWhile e c = do
        savingHeap $ do
        killVars e
        killVars c
        e' <- evalFullCmd e
        c' <- evalFullComp c
        whileC e' c' >>= partialComp

    residualFor ann v tau e1 e2 e3 =
        savingHeap $
        extendVarBinds [(v, UnknownV)] $ do
        killVars e3
        e3' <- evalFullComp e3
        forC ann v tau e1 e2 e3' >>= partialComp

evalWhile :: forall a . (ModifiedVars a Var, Eval a)
          => Exp
          -> a
          -> EvalM (Val a)
evalWhile e_cond body =
    evalLoop body $
    evalCond >>= loop
  where
    loop :: Val Exp -> EvalM (Val a)
    loop (ReturnV val) | isTrue val = do
        val2 <- evalBody
        case val2 of
          ReturnV {} -> evalCond >>= loop
          CmdV {}    -> residualWhile e_cond body
          CompV {}   -> residualWhile e_cond body
          _          -> faildoc $ text "Bad body evaluation in while:" <+> ppr val2

    loop (ReturnV val) | isFalse val =
        return $ returnUnit

    loop (CmdV {}) =
        residualWhile e_cond body

    loop val =
        faildoc $ text "Bad condition evaluation in while:" <+> ppr val

    evalCond :: EvalM (Val Exp)
    evalCond = eval e_cond

    evalBody :: EvalM (Val a)
    evalBody = eval body

evalFor :: forall a . (ModifiedVars a Var, Eval a)
        => UnrollAnn
        -> Var
        -> Type
        -> Exp
        -> Exp
        -> a
        -> EvalM (Val a)
evalFor ann v tau e1 e2 body = do
    start <- evalExp e1
    len   <- evalExp e2
    withUniqVar v $ \v' ->
        evalLoop body $
        extendVars [(v, tau)] $
        go v' start len
  where
    go :: Var -> Val Exp -> Val Exp -> EvalM (Val a)
    go v' start@(FixV I _ _ (BP 0) r_start) len@(FixV I _ _ (BP 0) r_len) =
        loop (numerator r_start) (numerator (r_start + r_len))
      where
        loop :: Integer -> Integer -> EvalM (Val a)
        loop !i !end | i < end = do
            val3 <- extendVarBinds [(v', toIdxVal i)] $ eval body
            case val3 of
              ReturnV {}     -> loop (i+1) end
              CompReturnV {} -> loop (i+1) end
              CmdV {}        -> residualFor ann v' tau (toExp start) (toExp len) body
              CompV {}       -> residualFor ann v' tau (toExp start) (toExp len) body
              _              -> faildoc $ text "Bad body evaluation in for:" <+> ppr val3

        loop _ _ =
            return $ returnUnit

    go v' start len =
        residualFor ann v' tau (toExp start) (toExp len) body

    toIdxVal :: Integral i => i -> Val Exp
    toIdxVal i = FixV sc s w bp (fromIntegral i)
      where
        FixT sc s w bp _ = tau

-- | Attempt to execute a loop. If the loop cannot be fully evaluated, we
-- perform the following steps:
--
-- 1. Restore the initial heap.
--
-- 2. Kill all variables that the loop could have been modified by the loop,
-- i.e., the free variables of @body@.
--
-- 3. Return a command consisting of the initial heap and the
-- partially-evaluated loop.
evalLoop :: ModifiedVars e Var => e -> EvalM (Val a) -> EvalM (Val a)
evalLoop body m = do
    h   <- getHeap
    val <- m
    case val of
      ReturnV {}     -> return val
      CompReturnV {} -> return val
      CmdV _ e'      -> do putHeap h
                           killVars body
                           partial $ CmdV h e'
      CompV _ c'     -> do putHeap h
                           killVars body
                           partial $ CompV h c'
      _              -> faildoc $ text "Bad loop:" <+> ppr val

evalIdx :: Val Exp -> Val Exp -> Maybe Int -> EvalM (Val Exp)
evalIdx (RefV r) start len =
    return $ RefV $ IdxR r start len

evalIdx (ArrayV vs) (FixV I _ _ (BP 0) r) Nothing =
    case vs P.!? start of
      Nothing  -> faildoc $
                  text "Array index" <+> ppr start <+>
                  text "out of bounds" <+> parens (ppr (P.length vs))
      Just val -> return val
  where
    start :: Int
    start = fromIntegral (numerator r)

evalIdx (ArrayV vs) (FixV I _ _ (BP 0) r) (Just len) =
    ArrayV <$> P.slice start len vs
  where
    start :: Int
    start = fromIntegral (numerator r)

evalIdx (SliceV arr start _len) i Nothing =
    return $ IdxV arr (start + i)

evalIdx (SliceV arr start0 _len0) start (Just len) =
    return $ SliceV arr (start0 + start) len

evalIdx v_arr v_start Nothing =
    return $ IdxV v_arr v_start

evalIdx v_arr v_start (Just len) =
    return $ SliceV v_arr v_start len

evalProj :: Val Exp -> Field -> EvalM (Val Exp)
evalProj (RefV r) f =
    return $ RefV $ ProjR r f

evalProj (StructV _ kvs) f =
    case Map.lookup f kvs of
      Nothing  -> faildoc $ text "Unknown struct field" <+> ppr f
      Just val -> return val

evalProj val f =
    partialExp $ ProjE (toExp val) f noLoc

-- | @'transformExpVal' f val'@ transforms a value of type @'Val' Exp@ by
-- applying f. Note that 'transformExpVal' will convert some sub-term of its
-- @Val Exp@ to an 'ExpV' if it isn't already, so even if @f@ is the identity
-- function, 'transformExpVal' /is not/ the identity function.
transformExpVal :: (Exp -> Exp) -> Val Exp -> EvalM (Val Exp)
transformExpVal f val0 =
    go val0
  where
    go :: Val Exp -> EvalM (Val Exp)
    go (ReturnV val) = ReturnV <$> go val
    go (ExpV e)      = partial $ ExpV   $ f e
    go (CmdV h e)    = partial $ CmdV h $ f e
    go v             = partial $ ExpV   $ f (toExp v)

-- | @'transformCompVal' f val'@ transforms a value of type @'Val' Comp@ by
-- applying f. Note that 'transformCompVal' will convert some sub-term of its
-- @Val Comp@ to a 'CompV' if it isn't already, so even if @f@ is the identity
-- function, 'transformCompVal' /is not/ the identity function.
transformCompVal :: (LComp -> EvalM LComp) -> Val LComp -> EvalM (Val LComp)
transformCompVal f val =
    toComp val >>= f >>= partialComp

-- | Produce a default value of the given type.
defaultValue :: Type -> EvalM (Maybe (Val Exp))
defaultValue tau =
    runMaybeT $ go tau
  where
    go :: Type -> MaybeT EvalM (Val Exp)
    go (UnitT {})         = return UnitV
    go (BoolT {})         = return $ BoolV False
    go (FixT sc s w bp _) = return $ FixV sc s w bp 0
    go (FloatT fp _)      = return $ FloatV fp 0
    go (StringT {})       = return $ StringV ""

    go (StructT s _) = do
        StructDef s flds _ <- lift $ lookupStruct s
        let (fs, taus)     =  unzip flds
        vals               <- mapM go taus
        return $ StructV s (Map.fromList (fs `zip` vals))

    go (ArrT (ConstI n _) tau _) = do
        val <- go tau
        return $ ArrayV (P.replicateDefault n val)

    go tau =
        faildoc $ text "Cannot generate default value for type" <+> ppr tau

-- | Given a type and a value, return 'True' if the value is the
-- default of that type and 'False' otherwise.
isDefaultValue :: Val Exp -> Bool
isDefaultValue UnitV            = True
isDefaultValue (BoolV False)    = True
isDefaultValue (FixV _ _ _ _ 0) = True
isDefaultValue (FloatV _ 0)     = True
isDefaultValue (StringV "")     = True
isDefaultValue (StructV _ flds) = all isDefaultValue (Map.elems flds)
isDefaultValue (ArrayV vals)    = all isDefaultValue (P.toList vals)
isDefaultValue _                = False

-- | Return 'True' if a 'Val' is completely known, even if it is a residual,
-- 'False' otherwise.
isKnown :: Val Exp -> Bool
isKnown UnknownV         = False
isKnown (BoolV {})       = True
isKnown (FixV {})        = True
isKnown (FloatV {})      = True
isKnown (StringV {})     = True
isKnown (StructV _ flds) = all isKnown (Map.elems flds)
isKnown (ArrayV vals)    = isKnown (P.defaultValue vals) &&
                           all (isKnown . snd) (P.nonDefaultValues vals)
isKnown (IdxV arr i)     = isKnown arr && isKnown i
isKnown (SliceV arr i _) = isKnown arr && isKnown i
isKnown (ExpV {})        = True
isKnown _                = False
