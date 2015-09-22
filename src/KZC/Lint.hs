{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      :  KZC.Lint
-- Copyright   :  (c) 2015 Drexel University
-- License     :  BSD-style
-- Maintainer  :  mainland@cs.drexel.edu

module KZC.Lint (
    withTc,

    checkDecls,

    inferExp,
    checkExp,

    inferKind,
    checkKind
  ) where

import Control.Monad (when,
                      zipWithM_,
                      void)
import Data.List (nub)
import Data.Loc
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Text.PrettyPrint.Mainland

import KZC.Core.Smart
import KZC.Core.Syntax
import KZC.Error
import KZC.Lint.Monad
import KZC.Summary
import KZC.Vars

checkDecls :: [Decl] -> Tc r s ()
checkDecls [] =
    return ()

checkDecls (decl:decls) =
    checkDecl  decl $
    checkDecls decls

checkDecl :: Decl -> Tc r s a -> Tc r s a
checkDecl decl@(LetD v tau e _) k = do
    withSummaryContext decl $ do
        void $ inferKind tau
        tau' <- withExpContext e $
                inSTScope tau $
                inferExp e >>= absSTScope
        checkTypeEquality tau' tau
    extendVars [(v, tau)] k

checkDecl decl@(LetFunD f iotas vbs tau_ret e l) k = do
    withSummaryContext decl $
        checkKind tau PhiK
    extendVars [(f, tau)] $ do
    withSummaryContext decl $ do
        tau_ret' <- withExpContext e $
                    extendIVars (iotas `zip` repeat IotaK) $
                    extendVars vbs $
                    inSTScope tau_ret $
                    inferExp e >>= absSTScope
        checkTypeEquality tau_ret' tau_ret
    k
  where
    tau :: Type
    tau = FunT iotas (map snd vbs) tau_ret l

checkDecl decl@(LetExtFunD f iotas vbs tau_ret l) k = do
    withSummaryContext decl $ checkKind tau PhiK
    extendVars [(f, tau)] k
  where
    tau :: Type
    tau = FunT iotas (map snd vbs) tau_ret l

checkDecl decl@(LetRefD v tau Nothing _) k = do
    withSummaryContext decl $ checkKind tau TauK
    extendVars [(v, refT tau)] k

checkDecl decl@(LetRefD v tau (Just e) _) k = do
    withSummaryContext decl $ do
        checkKind tau TauK
        checkExp e tau
    extendVars [(v, refT tau)] k

checkDecl decl@(LetStructD s flds l) k = do
    withSummaryContext decl $ do
        checkStructNotRedefined s
        checkDuplicates "field names" fnames
        mapM_ (\tau -> checkKind tau TauK) taus
    extendStructs [StructDef s flds l] k
  where
    (fnames, taus) = unzip flds

    checkStructNotRedefined :: Struct -> Tc r s ()
    checkStructNotRedefined s = do
      maybe_sdef <- maybeLookupStruct s
      case maybe_sdef of
        Nothing   -> return ()
        Just sdef -> faildoc $ text "Struct" <+> ppr s <+> text "redefined" <+>
                     parens (text "original definition at" <+> ppr (locOf sdef))

inferExp :: Exp -> Tc r s Type
inferExp (ConstE c l) =
    checkConst c
  where
    checkConst :: Const -> Tc r s Type
    checkConst UnitC       = return (UnitT l)
    checkConst(BoolC {})   = return (BoolT l)
    checkConst(BitC {})    = return (BitT l)
    checkConst(IntC w _)   = return (IntT w l)
    checkConst(FloatC w _) = return (FloatT w l)
    checkConst(StringC _)  = return (StringT l)

    checkConst(ArrayC cs) = do
        taus <- mapM checkConst cs
        case taus of
          [] -> faildoc $ text "Empty array"
          tau:taus | all (== tau) taus -> return tau
                   | otherwise -> faildoc $ text "Constant array elements do not all have the same type"

inferExp (VarE v _) =
    lookupVar v

inferExp (UnopE op e1 _) = do
    tau1 <- inferExp e1
    unop op tau1
  where
    unop :: Unop -> Type -> Tc r s Type
    unop Lnot tau = do
        checkBoolT tau
        return tau

    unop Bnot tau = do
        checkBitT tau
        return tau

    unop Neg tau = do
        checkSignedNumT tau
        return tau

    unop (Cast tau2) tau1 = do
        checkCast tau1 tau2
        return tau2

    unop Len tau = do
        _ <- checkArrT tau
        return intT

inferExp (BinopE op e1 e2 _) = do
    tau1 <- inferExp e1
    tau2 <- inferExp e2
    binop op tau1 tau2
  where
    binop :: Binop -> Type -> Type -> Tc r s Type
    binop Lt tau1 tau2 =
        checkOrdBinop tau1 tau2

    binop Le tau1 tau2 =
        checkOrdBinop tau1 tau2

    binop Eq tau1 tau2 =
        checkEqBinop tau1 tau2

    binop Ge tau1 tau2 =
        checkOrdBinop tau1 tau2

    binop Gt tau1 tau2 =
        checkOrdBinop tau1 tau2

    binop Ne tau1 tau2 =
        checkEqBinop tau1 tau2

    binop Land tau1 tau2 =
        checkBoolBinop tau1 tau2

    binop Lor tau1 tau2 =
        checkBoolBinop tau1 tau2

    binop Band tau1 tau2 =
        checkBitBinop tau1 tau2

    binop Bor tau1 tau2 =
        checkBitBinop tau1 tau2

    binop Bxor tau1 tau2 =
        checkBitBinop tau1 tau2

    binop LshL tau1 tau2 =
        checkBitShiftBinop tau1 tau2

    binop LshR tau1 tau2 =
        checkBitShiftBinop tau1 tau2

    binop AshR tau1 tau2 =
        checkBitShiftBinop tau1 tau2

    binop Add tau1 tau2 =
        checkNumBinop tau1 tau2

    binop Sub tau1 tau2 =
        checkNumBinop tau1 tau2

    binop Mul tau1 tau2 =
        checkNumBinop tau1 tau2

    binop Div tau1 tau2 =
        checkNumBinop tau1 tau2

    binop Rem tau1 tau2 =
        checkNumBinop tau1 tau2

    binop Pow tau1 tau2 =
        checkNumBinop tau1 tau2

    checkEqBinop :: Type -> Type -> Tc r s Type
    checkEqBinop tau1 tau2 = do
        checkEqT tau1
        checkTypeEquality tau2 tau1
        return boolT

    checkOrdBinop :: Type -> Type -> Tc r s Type
    checkOrdBinop tau1 tau2 = do
        checkOrdT tau1
        checkTypeEquality tau2 tau1
        return boolT

    checkBoolBinop :: Type -> Type -> Tc r s Type
    checkBoolBinop tau1 tau2 = do
        checkBoolT tau1
        checkTypeEquality tau2 tau1
        return tau1

    checkNumBinop :: Type -> Type -> Tc r s Type
    checkNumBinop tau1 tau2 = do
        checkNumT tau1
        checkTypeEquality tau2 tau1
        return tau1

    checkBitBinop :: Type -> Type -> Tc r s Type
    checkBitBinop tau1 tau2 = do
        checkBitT tau1
        checkTypeEquality tau2 tau1
        return tau1
        return tau1

    checkBitShiftBinop :: Type -> Type -> Tc r s Type
    checkBitShiftBinop tau1 tau2 = do
        checkBitT tau1
        checkIntT tau2
        return tau1

inferExp (IfE e1 e2 e3 _) = do
    checkExp e1 boolT
    tau <- withExpContext e2 $ inferExp e2
    withExpContext e3 $ checkExp e3 tau
    return tau

inferExp (LetE decl body _) =
    checkDecl decl $ inferExp body

inferExp (CallE f ies es _) = do
    (ivs, taus, tau_ret) <- inferExp f >>= checkFunT
    checkNumIotas (length ies) (length ivs)
    checkNumArgs  (length es)  (length taus)
    extendIVars (ivs `zip` repeat IotaK) $ do
    mapM_ checkIotaArg ies
    let theta = Map.fromList (ivs `zip` ies)
    let phi   = fvs taus
    zipWithM_ checkArg es (subst theta phi taus)
    appSTScope (subst theta phi tau_ret)
  where
    checkIotaArg :: Iota -> Tc r s ()
    checkIotaArg (ConstI {}) =
        return ()

    checkIotaArg (VarI iv _) =
        void $ lookupIVar iv

    checkArg :: Exp -> Type -> Tc r s ()
    checkArg e tau =
        withExpContext e $
        checkExp e tau

    checkNumIotas :: Int -> Int -> Tc r s ()
    checkNumIotas n nexp =
        when (n /= nexp) $
             faildoc $
             text "Expected" <+> ppr nexp <+>
             text "index expression arguments but got" <+> ppr n

    checkNumArgs :: Int -> Int -> Tc r s ()
    checkNumArgs n nexp =
        when (n /= nexp) $
             faildoc $
             text "Expected" <+> ppr nexp <+>
             text "arguments but got" <+> ppr n

inferExp (DerefE e l) = do
    tau <- inferExp e >>= checkRefT
    appSTScope $ ST [s,a,b] (C tau) (tyVarT s) (tyVarT a) (tyVarT b) l
  where
    s, a, b :: TyVar
    s = "s"
    a = "a"
    b = "b"

inferExp (AssignE e1 e2 l) = do
    tau  <- inferExp e1 >>= checkRefT
    tau' <- inferExp e2
    withExpContext e2 $ checkTypeEquality tau' tau
    appSTScope $ ST [s,a,b] (C (UnitT l)) (tyVarT s) (tyVarT a) (tyVarT b) l
  where
    s, a, b :: TyVar
    s = "s"
    a = "a"
    b = "b"

inferExp (WhileE e1 e2 _) = do
    withExpContext e1 $ do
        (tau, _, _, _) <- inferExp e1 >>= checkSTC
        checkTypeEquality tau boolT
    withExpContext e2 $ do
        tau <- inferExp e2
        void $ checkSTCUnit tau
        return tau

inferExp (ForE _ v tau e1 e2 e3 _) = do
    checkIntT tau
    withExpContext e1 $
        checkExp e1 tau
    withExpContext e2 $
        checkExp e2 tau
    extendVars [(v, tau)] $
        withExpContext e3 $ do
        tau_body <- inferExp e3
        void $ checkSTCUnit tau_body
        return tau_body

inferExp (ArrayE es l) = do
    taus <- mapM inferExp es
    case taus of
      [] -> faildoc $ text "Empty array expression"
      tau:taus -> do mapM_ (checkTypeEquality tau) taus
                     return $ ArrT (ConstI (length es) l) tau l

inferExp (IdxE e1 e2 len l) = do
    tau <- withExpContext e1 $ inferExp e1
    withExpContext e2 $ inferExp e2 >>= checkIntT
    go tau
  where
    go :: Type -> Tc r s Type
    go (RefT (ArrT _ tau _) _) =
        return $ RefT (mkArrSlice tau len) l

    go (ArrT _ tau _) = do
        return $ mkArrSlice tau len

    go tau =
        faildoc $ nest 2 $ group $
        text "Expected array type but got:" <+/> ppr tau

    mkArrSlice :: Type -> Maybe Int -> Type
    mkArrSlice tau Nothing  = tau
    mkArrSlice tau (Just i) = ArrT (ConstI i l) tau l

inferExp (ProjE e f l) = do
    tau <- withExpContext e $ inferExp e
    go tau
  where
    go :: Type -> Tc r s Type
    go (RefT tau _) = do
        sdef  <- checkStructT tau >>= lookupStruct
        tau_f <- checkStructFieldT sdef f
        return $ RefT tau_f l

    go tau = do
        sdef  <- checkStructT tau >>= lookupStruct
        tau_f <- checkStructFieldT sdef f
        return tau_f

inferExp e0@(StructE s flds l) =
    withExpContext e0 $ do
    StructDef _ fldDefs _ <- lookupStruct s
    checkMissingFields flds fldDefs
    checkExtraFields flds fldDefs
    mapM_ (checkField fldDefs) flds
    return $ StructT s l
  where
    checkField :: [(Field, Type)] -> (Field, Exp) -> Tc r s ()
    checkField fldDefs (f, e) = do
      tau <- case lookup f fldDefs of
               Nothing  -> panicdoc $ "checkField: missing field!"
               Just tau -> return tau
      checkExp e tau

    checkMissingFields :: [(Field, Exp)] -> [(Field, Type)] -> Tc r s ()
    checkMissingFields flds fldDefs =
        when (not (Set.null missing)) $
          faildoc $
            text "Struct definition has missing fields:" <+>
            (commasep . map ppr . Set.toList) missing
      where
        fs, fs', missing :: Set Field
        fs  = Set.fromList [f | (f,_) <- flds]
        fs' = Set.fromList [f | (f,_) <- fldDefs]
        missing = fs Set.\\ fs'

    checkExtraFields :: [(Field, Exp)] -> [(Field, Type)] -> Tc r s ()
    checkExtraFields flds fldDefs =
        when (not (Set.null extra)) $
          faildoc $
            text "Struct definition has extra fields:" <+>
            (commasep . map ppr . Set.toList) extra
      where
        fs, fs', extra :: Set Field
        fs  = Set.fromList [f | (f,_) <- flds]
        fs' = Set.fromList [f | (f,_) <- fldDefs]
        extra = fs' Set.\\ fs

inferExp (PrintE _ es l) = do
    mapM_ inferExp es
    appSTScope $ ST [s,a,b] (C (UnitT l)) (tyVarT s) (tyVarT a) (tyVarT b) l
  where
    s, a, b :: TyVar
    s = "s"
    a = "a"
    b = "b"

inferExp (ErrorE nu _ l) =
    appSTScope $ ST [s,a,b] (C nu) (tyVarT s) (tyVarT a) (tyVarT b) l
  where
    s, a, b :: TyVar
    s = "s"
    a = "a"
    b = "b"

inferExp (ReturnE _ e l) = do
    tau <- inferExp e
    appSTScope $ ST [s,a,b] (C tau) (tyVarT s) (tyVarT a) (tyVarT b) l
  where
    s, a, b :: TyVar
    s = "s"
    a = "a"
    b = "b"

inferExp (BindE bv e1 e2 _) = do
    (tau', s,  a,  b)  <- withExpContext e1 $ do
                          inferExp e1 >>= appSTScope >>= checkSTC
    case bv of
      WildV       -> return ()
      BindV _ tau -> checkTypeEquality tau' tau
    (omega,  s', a', b') <- withExpContext e2 $
                            extendBindVars [bv] $
                            inferExp e2 >>= appSTScope >>= checkST
    withExpContext e2 $ do
    checkTypeEquality s' s
    checkTypeEquality a' a
    checkTypeEquality b' b
    return $ stT omega s a b

inferExp (TakeE tau l) = do
    checkKind tau TauK
    appSTScope $ ST [a,b] (C tau) (tyVarT a) (tyVarT a) (tyVarT b) l
  where
    a, b :: TyVar
    a = "a"
    b = "b"

inferExp (TakesE i tau l) = do
    checkKind tau TauK
    appSTScope $ ST [a,b] (C (arrKnownT i tau)) (tyVarT a) (tyVarT a) (tyVarT b) l
  where
    a, b :: TyVar
    a = "a"
    b = "b"

inferExp (EmitE e l) = do
    tau <- withExpContext e $ inferExp e
    appSTScope $ ST [s,a] (C (UnitT l)) (tyVarT s) (tyVarT a) tau l
  where
    s, a :: TyVar
    s = "s"
    a = "a"

inferExp (EmitsE e l) = do
    (_, tau) <- withExpContext e $ inferExp e >>= checkArrT
    appSTScope $ ST [s,a] (C (UnitT l)) (tyVarT s) (tyVarT a) tau l
  where
    s, a :: TyVar
    s = "s"
    a = "a"

inferExp (RepeatE _ e l) = do
    (s, a, b) <- withExpContext e $ inferExp e >>= appSTScope >>= checkSTCUnit
    return $ ST [] T s a b l

inferExp e0@(ParE _ b e1 e2 l) = do
    (s, a, c) <- askSTIndTypes
    (omega1, s', a',    b') <- withExpContext e1 $
                               localSTIndTypes (Just (s, a, b)) $
                               inferExp e1 >>= checkST
    (omega2, b'', b''', c') <- withExpContext e2 $
                               localSTIndTypes (Just (b, b, c)) $
                               inferExp e2 >>= checkST
    withExpContext e1 $
        checkTypeEquality (ST [] omega1 s'  a'   b' l) (ST [] omega1 s a b l)
    withExpContext e2 $
        checkTypeEquality (ST [] omega2 b'' b''' c' l) (ST [] omega2 b b c l)
    omega <- withExpContext e0 $
             joinOmega omega1 omega2
    return $ ST [] omega s a c l
  where
    joinOmega :: Omega -> Omega -> Tc r s Omega
    joinOmega omega1@(C {}) (T {})        = return omega1
    joinOmega (T {})        omega2@(C {}) = return omega2
    joinOmega omega1@(T {}) (T {})        = return omega1

    joinOmega omega1 omega2 =
        faildoc $ text "Cannot join" <+> ppr omega1 <+> text "and" <+> ppr omega2

checkExp :: Exp -> Type -> Tc r s ()
checkExp e tau = do
    tau' <- inferExp e
    checkTypeEquality tau' tau

-- | @checkCast tau1 tau2@ checks that a value of type @tau1@ can be cast to a
-- value of type @tau2@.
checkCast :: Type -> Type -> Tc r s ()
checkCast tau1 tau2 | tau1 == tau2 =
    return ()

checkCast (IntT {}) (IntT {}) =
    return ()

checkCast (IntT {}) (BitT {}) =
    return ()

checkCast (BitT {}) (IntT {}) =
    return ()

checkCast (IntT {}) (FloatT {}) =
    return ()

checkCast (FloatT {}) (IntT {}) =
    return ()

checkCast (FloatT {}) (FloatT {}) =
    return ()

checkCast (StructT s1 _) (StructT s2 _) | isComplexStruct s1 && isComplexStruct s2=
    return ()

checkCast tau1 tau2 =
    faildoc $ text "Cannot cast" <+> ppr tau1 <+> text "to" <+> ppr tau2

checkTypeEquality :: Type -> Type -> Tc r s ()
checkTypeEquality tau1 tau2 =
    checkT Map.empty Map.empty tau1 tau2
  where
    checkT :: Map TyVar TyVar
           -> Map IVar IVar
           -> Type
           -> Type
           -> Tc r s ()
    checkT _ _ (UnitT {}) (UnitT {}) = return ()
    checkT _ _ (BoolT {}) (BoolT {}) = return ()
    checkT _ _ (BitT {})  (BitT {})  = return ()

    checkT _ _ (IntT w1 _)   (IntT w2 _)     | w1 == w2 = return ()
    checkT _ _ (FloatT w1 _) (FloatT w2 _)   | w1 == w2 = return ()

    checkT _ _ (StringT {}) (StringT {})  = return ()

    checkT theta phi (ArrT iota1 tau1 _) (ArrT iota2 tau2 _) = do
        checkI phi iota1 iota2
        checkT theta phi tau1 tau2

    checkT _ _ (StructT s1 _) (StructT s2 _) | s1 == s2 =
        return ()

    checkT theta phi (ST alphas_a omega_a tau1_a tau2_a tau3_a _)
                     (ST alphas_b omega_b tau1_b tau2_b tau3_b _)
        | length alphas_a == length alphas_b = do
          checkO theta phi omega_a omega_b
          checkT theta phi tau1_a tau1_b
          checkT theta' phi tau2_a tau2_b
          checkT theta' phi tau3_a tau3_b
      where
        theta' :: Map TyVar TyVar
        theta' = Map.fromList (alphas_a `zip` alphas_b) `Map.union` theta

    checkT theta phi (FunT iotas_a taus_a tau_a _)
                     (FunT iotas_b taus_b tau_b _)
        | length iotas_a == length iotas_b && length taus_a == length taus_b = do
          zipWithM_ (checkT theta phi') taus_a taus_b
          checkT theta phi' tau_a tau_b
      where
        phi' :: Map IVar IVar
        phi' = Map.fromList (iotas_a `zip` iotas_b) `Map.union` phi

    checkT theta phi (RefT tau1 _) (RefT tau2 _) =
        checkT theta phi tau1 tau2

    checkT theta _ (TyVarT alpha _) (TyVarT beta _)
        | fromMaybe alpha (Map.lookup alpha theta) == beta =
        return ()

    checkT _ _ _ _ =
        err

    checkO :: Map TyVar TyVar
           -> Map IVar IVar
           -> Omega
           -> Omega
           -> Tc r s ()
    checkO theta phi (C tau1) (C tau2) =
        checkT theta phi tau1 tau2

    checkO _ _ (T {}) (T {}) =
        return ()

    checkO _ _ _ _ =
        err

    checkI :: Map IVar IVar
           -> Iota
           -> Iota
           -> Tc r s ()
    checkI _ (ConstI i1 _) (ConstI i2 _) | i1 == i2 =
        return ()

    checkI phi (VarI iv1 _) (VarI iv2 _)
        | fromMaybe iv1 (Map.lookup iv1 phi) == iv2 =
        return ()

    checkI _ _ _ =
        err

    err :: Tc r s ()
    err =
      faildoc $ align $
          text "Expected type:" <+> ppr tau2 </>
          text "but got:      " <+> ppr tau1

inferKind :: Type -> Tc r s Kind
inferKind tau =
    inferType tau
  where
    inferType :: Type -> Tc r s Kind
    inferType (UnitT {})   = return TauK
    inferType (BoolT {})   = return TauK
    inferType (BitT {})    = return TauK
    inferType (IntT {})    = return TauK
    inferType (FloatT {})  = return TauK
    inferType (StringT {}) = return TauK
    inferType (StructT {}) = return TauK

    inferType (ArrT iota tau _) = do
        inferIota iota
        kappa <- inferType tau
        checkKindEquality kappa TauK
        return TauK

    inferType (ST alphas omega tau1 tau2 tau3 _) =
        extendTyVars (alphas `zip` repeat TauK) $ do
        inferOmega omega
        checkKind tau1 TauK
        checkKind tau2 TauK
        checkKind tau3 TauK
        return MuK

    inferType (RefT tau _) = do
        checkKind tau TauK
        return RhoK

    inferType (FunT ivs taus tau_ret _) =
        extendIVars (ivs `zip` repeat IotaK) $ do
        mapM_ checkArgKind taus
        checkRetKind tau_ret
        return PhiK
      where
        checkArgKind :: Type -> Tc r s ()
        checkArgKind tau = do
            kappa <- inferType tau
            case kappa of
              TauK -> return ()
              RhoK -> return ()
              MuK  -> return ()
              _    -> checkKindEquality kappa TauK

        checkRetKind :: Type -> Tc r s ()
        checkRetKind tau = do
            kappa <- inferType tau
            case kappa of
              TauK -> return ()
              MuK  -> return ()
              _    -> checkKindEquality kappa TauK

    inferType (TyVarT alpha _) =
        lookupTyVar alpha

    inferIota :: Iota -> Tc r s Kind
    inferIota (ConstI {}) = return IotaK
    inferIota (VarI iv _) = lookupIVar iv

    inferOmega :: Omega -> Tc r s Kind
    inferOmega (C tau) = do
        checkKind tau TauK
        return OmegaK

    inferOmega T =
        return OmegaK

checkKind :: Type -> Kind -> Tc r s ()
checkKind tau kappa = do
    kappa' <- inferKind tau
    checkKindEquality kappa' kappa

checkKindEquality :: Kind -> Kind -> Tc r s ()
checkKindEquality kappa1 kappa2 | kappa1 == kappa2 =
    return ()

checkKindEquality kappa1 kappa2 =
    faildoc $ align $
    text "Expected kind:" <+> ppr kappa2 </>
    text "but got:      " <+> ppr kappa1

absSTScope :: Type -> Tc r s Type
absSTScope (ST [] omega s a b l) = do
    (s',a',b') <- askSTIndTypes
    let alphas =  nub [alpha | TyVarT alpha _ <- [s',a',b']]
    return $ ST alphas omega s a b l

absSTScope tau =
    return tau

appSTScope :: Type -> Tc r s Type
appSTScope tau@(ST alphas omega s a b l) = do
    (s',a',b') <- askSTIndTypes
    let theta = Map.fromList [(alpha, tau) | (TyVarT alpha _, tau) <- [s,a,b] `zip` [s',a',b']
                                           , alpha `elem` alphas]
    let phi   = fvs tau
    return $ ST [] omega
                (subst theta phi s)
                (subst theta phi a)
                (subst theta phi b)
                l

appSTScope tau =
    return tau

-- | Check that a type supports equality.
checkEqT :: Type -> Tc r s ()
checkEqT tau =
    checkKind tau TauK

-- | Check that a type supports ordering.
checkOrdT :: Type -> Tc r s ()
checkOrdT (IntT _ _)                        = return ()
checkOrdT (FloatT _ _)                      = return ()
checkOrdT (StructT s _) | isComplexStruct s = return ()
checkOrdT tau =
    faildoc $ nest 2 $ group $
    text "Expected comparable type but got:" <+/> ppr tau

-- | Check that a type is a type on which we can perform Boolean operations.
checkBoolT :: Type -> Tc r s ()
checkBoolT (BitT {})  = return ()
checkBoolT (BoolT {}) = return ()
checkBoolT (IntT {})  = return ()
checkBoolT tau =
    faildoc $ nest 2 $ group $
    text "Expected a Boolean type, e.g., bit, bool, or int, but got:" <+/> ppr tau

-- | Check that a type is a type on which we can perform bitwise operations.
checkBitT :: Type -> Tc r s ()
checkBitT (BitT {})  = return ()
checkBitT (BoolT {}) = return ()
checkBitT (IntT {})  = return ()
checkBitT tau =
    faildoc $ nest 2 $ group $
    text "Expected a bit type, e.g., bit or int, but got:" <+/> ppr tau

-- | Check that a type is an integer type.
checkIntT :: Type -> Tc r s ()
checkIntT (IntT _ _)  = return ()
checkIntT tau =
    faildoc $ nest 2 $ group $
    text "Expected integer type but got:" <+/> ppr tau

-- | Check that a type is a numerical type.
checkNumT :: Type -> Tc r s ()
checkNumT (IntT _ _)                        = return ()
checkNumT (FloatT _ _)                      = return ()
checkNumT (StructT s _) | isComplexStruct s = return ()
checkNumT tau =
    faildoc $ nest 2 $ group $
    text "Expected numerical type but got:" <+/> ppr tau

-- | Check that a type is a /signed/ numerical type.
checkSignedNumT (IntT _ _)                        = return ()
checkSignedNumT (FloatT _ _)                      = return ()
checkSignedNumT (StructT s _) | isComplexStruct s = return ()
checkSignedNumT tau =
    faildoc $ nest 2 $ group $
    text "Expected numerical type but got:" <+/> ppr tau

-- | Check that a type is an @arr \iota \alpha@ type, returning @\iota@ and
-- @\alpha@.
checkArrT :: Type -> Tc r s (Iota, Type)
checkArrT (ArrT iota alpha _) =
    return (iota, alpha)

checkArrT tau =
    faildoc $ nest 2 $ group $
    text "Expected array type but got:" <+/> ppr tau

-- | Check that a type is a struct type, returning the name of the struct.
checkStructT :: Type -> Tc r s Struct
checkStructT (StructT s _) =
    return s

checkStructT tau =
    faildoc $ nest 2 $
    text "Expected struct type, but got:" <+/> ppr tau

checkStructFieldT :: StructDef -> Field -> Tc r s Type
checkStructFieldT (StructDef s flds _) f =
    case lookup f flds of
      Just tau -> return tau
      Nothing ->
          faildoc $
          text "Struct" <+> ppr s <+>
          text "does not have a field named" <+> ppr f

checkST :: Type -> Tc r s (Omega, Type, Type, Type)
checkST (ST [] omega s a b _) =
    return (omega, s, a, b)

checkST tau =
    faildoc $ nest 2 $ group $
    text "Expected type of the form 'ST omega s a b' but got:" <+/> ppr tau

checkSTC :: Type -> Tc r s (Type, Type, Type, Type)
checkSTC (ST [] (C tau) s a b _) =
    return (tau, s, a, b)

checkSTC tau =
    faildoc $ nest 2 $ group $
    text "Expected type of the form 'ST (C tau) s a b' but got:" </> ppr tau

checkSTCUnit :: Type -> Tc r s (Type, Type, Type)
checkSTCUnit (ST _ (C (UnitT _)) s a b _) =
    return (s, a, b)

checkSTCUnit tau =
    faildoc $ nest 2 $ group $
    text "Expected type of the form 'ST (C ()) s a b' but got:" <+/> ppr tau

checkRefT :: Type -> Tc r s Type
checkRefT (RefT tau _) =
    return tau

checkRefT tau =
    faildoc $ nest 2 $ group $
    text "Expected ref type but got:" <+/> ppr tau

checkFunT :: Type -> Tc r s ([IVar], [Type], Type)
checkFunT (FunT iotas taus tau_ret _) =
    return (iotas, taus, tau_ret)

checkFunT tau =
    faildoc $ nest 2 $ group $
    text "Expected function type but got:" <+/> ppr tau
