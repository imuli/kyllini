{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      :  KZC.Lint.Monad
-- Copyright   :  (c) 2014-2015 Drexel University
-- License     :  BSD-style
-- Maintainer  :  mainland@cs.drexel.edu

module KZC.Cg.Monad (
    Cg,
    evalCg,

    Code(..),
    Comp(..),
    CComp,
    CExp(..),

    extend,
    lookupBy,

    extendVarCExps,
    lookupVarCExp,

    extendIVarCExps,
    lookupIVarCExp,

    tell,
    collect,
    collectDefinitions,
    collectDefinitions_,
    collectStmts,
    collectStmts_,

    inNewBlock,
    inNewBlock_,

    appendTopDef,
    appendTopDefs,
    appendTopDecl,
    appendTopDecls,
    appendDecl,
    appendDecls,
    appendStm,
    appendStms,

    traceNest,
    traceCg
  ) where

import Control.Applicative ((<$>))
import Control.Monad.Free
import Control.Monad.Reader
import Control.Monad.State
import Data.Foldable (toList)
import Data.List (foldl')
import Data.Loc
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Monoid
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Language.C.Quote.C
import qualified Language.C.Syntax as C
import System.IO (stderr)
import Text.PrettyPrint.Mainland

import KZC.Core.Syntax
import KZC.Error
import KZC.Flags
import KZC.Lint.Monad hiding (traceNest)
import KZC.Monad

-- | Contains generated code.
data Code = Code
    { -- | Top-level definitions
      defs  :: !(Seq C.Definition)
      -- | Local declarations
    , decls :: !(Seq C.InitGroup)
      -- | Local statements
    , stmts :: !(Seq C.Stm)
    }
  deriving (Eq, Ord, Show)

instance Monoid Code where
    mempty = Code { defs     = mempty
                  , decls    = mempty
                  , stmts    = mempty
                  }

    a `mappend` b = Code { defs  = defs a <> defs b
                         , decls = decls a <> decls b
                         , stmts = stmts a <> stmts b
                         }

data Comp a = CodeC Code a
            | TakeC (CExp -> a)
            | TakesC Int (CExp -> a)
            | EmitC CExp a
            | EmitsC Iota CExp a
            | IfC CExp CExp a a (CExp -> a)
            | RepeatC a
            | ArrC Type a a
            | BindC CExp CExp a
            | Done
  deriving (Functor)

type CComp = Free Comp CExp

data CExp = CVoid
          | CInt Integer     -- ^ Integer constant
          | CFloat Double    -- ^ Float constant
          | CExp C.Exp       -- ^ C expression
          | CArray CExp CExp -- ^ Array. The first argument is the array's
                             -- length, and the second is its contents.
          | CPtr CExp        -- ^ A pointer.
          | CComp CComp      -- ^ A computation.

instance ToExp CExp where
    toExp CVoid        = error "void compiled expression"
    toExp (CInt i)     = \_ -> [cexp|$int:i|]
    toExp (CFloat f)   = \_ -> [cexp|$float:(toRational f)|]
    toExp (CExp e)     = \_ -> e
    toExp (CArray _ e) = toExp e
    toExp (CPtr e)     = \_ -> [cexp|*$e|]
    toExp (CComp {})   = error "toExp: cannot convert CComp to a C expression"

instance Pretty CExp where
    ppr CVoid        = text "<void>"
    ppr (CInt i)     = ppr i
    ppr (CFloat f)   = ppr f
    ppr (CExp e)     = ppr e
    ppr (CPtr e)     = ppr [cexp|*$e|]
    ppr (CArray _ e) = ppr (toExp e noLoc)
    ppr (CComp {})   = text "<computation>"

type Cg a = Tc CgEnv CgState a

data CgEnv = CgEnv
    { errctx    :: ![ErrorContext]
    , nestdepth :: {-# UNPACK #-} !Int
    , varCExps  :: Map Var CExp
    , ivarCExps :: Map IVar CExp
    }

defaultCgEnv :: CgEnv
defaultCgEnv = CgEnv
    { errctx    = []
    , nestdepth = 0
    , varCExps  = mempty
    , ivarCExps = mempty
    }

data CgState = CgState
    { code :: Code }

defaultCgState :: CgState
defaultCgState = CgState
    { code = mempty }

evalCg :: Cg () -> KZC [C.Definition]
evalCg m = do
    s <- liftTc defaultCgEnv defaultCgState (m >> get)
    return $ (toList . defs . code) s

extend :: forall k v a . Ord k
       => (CgEnv -> Map k v)
       -> (CgEnv -> Map k v -> CgEnv)
       -> [(k, v)]
       -> Cg a
       -> Cg a
extend _ _ [] m = m

extend proj upd kvs m = do
    local (\env -> upd env (foldl' insert (proj env) kvs)) m
  where
    insert :: Map k v -> (k, v) -> Map k v
    insert mp (k, v) = Map.insert k v mp

lookupBy :: Ord k
         => (CgEnv -> Map k v)
         -> Cg v
         -> k
         -> Cg v
lookupBy proj onerr k = do
    maybe_v <- asks (Map.lookup k . proj)
    case maybe_v of
      Nothing  -> onerr
      Just v   -> return v

extendVarCExps :: [(Var, CExp)] -> Cg a -> Cg a
extendVarCExps ves m =
    extend varCExps (\env x -> env { varCExps = x }) ves m

lookupVarCExp :: Var -> Cg CExp
lookupVarCExp v =
    lookupBy varCExps onerr v
  where
    onerr = faildoc $ text "Compiled variable" <+> ppr v <+> text "not in scope"

extendIVarCExps :: [(IVar, CExp)] -> Cg a -> Cg a
extendIVarCExps ves m =
    extend ivarCExps (\env x -> env { ivarCExps = x }) ves m

lookupIVarCExp :: IVar -> Cg CExp
lookupIVarCExp v =
    lookupBy ivarCExps onerr v
  where
    onerr = faildoc $ text "Compiled variable" <+> ppr v <+> text "not in scope"

tell :: ToCode a => a -> Cg ()
tell c = modify $ \s -> s { code = code s <> toCode c }

class ToCode a where
    toCode :: a -> Code

instance ToCode Code where
    toCode code = code

instance ToCode C.Definition where
    toCode cdef = mempty { defs = Seq.singleton cdef }

instance ToCode [C.Definition] where
    toCode cdefs = mempty { defs = Seq.fromList cdefs }

instance ToCode C.InitGroup where
    toCode cdecl = mempty { decls = Seq.singleton cdecl }

instance ToCode [C.InitGroup] where
    toCode cdecls = mempty { decls = Seq.fromList cdecls }

instance ToCode C.Stm where
    toCode cstm = mempty { stmts = Seq.singleton cstm }

instance ToCode [C.Stm] where
    toCode cstms = mempty { stmts = Seq.fromList cstms }

collect :: Cg a -> Cg (a, Code)
collect m = do
    old_code <- gets code
    modify $ \s -> s { code = mempty }
    x <- m
    c <- gets code
    modify $ \s -> s { code = old_code }
    return (x, c)

collectDefinitions :: Cg a -> Cg ([C.Definition], a)
collectDefinitions m = do
    (x, c) <- collect m
    tell c { defs = mempty }
    return (toList (defs c), x)

collectDefinitions_ :: Cg () -> Cg ([C.Definition])
collectDefinitions_ m = do
    (defs, _) <- collectDefinitions m
    return defs

collectStmts :: Cg a -> Cg ([C.Stm], a)
collectStmts m = do
    (x, c) <- collect m
    tell c { stmts = mempty }
    return (toList (stmts c), x)

collectStmts_ :: Cg () -> Cg ([C.Stm])
collectStmts_ m = do
    (stms, _) <- collectStmts m
    return stms

inNewBlock :: Cg a -> Cg ([C.BlockItem], a)
inNewBlock m = do
    (x, c) <- collect m
    tell c { decls = mempty, stmts  = mempty }
    return ((map C.BlockDecl . toList . decls) c ++
            (map C.BlockStm .  toList . stmts) c, x)

inNewBlock_ :: Cg () -> Cg [C.BlockItem]
inNewBlock_ m =
    fst <$> inNewBlock m

appendTopDef :: C.Definition -> Cg ()
appendTopDef cdef =
  tell mempty { defs = Seq.singleton cdef }

appendTopDefs :: [C.Definition] -> Cg ()
appendTopDefs cdefs =
  tell mempty { defs = Seq.fromList cdefs }

appendTopDecl :: C.InitGroup -> Cg ()
appendTopDecl cdecl =
  tell mempty { defs = Seq.singleton (C.DecDef cdecl noLoc) }

appendTopDecls :: [C.InitGroup] -> Cg ()
appendTopDecls cdecls =
  tell mempty { defs = Seq.fromList [C.DecDef decl noLoc | decl <- cdecls] }

appendDecl :: C.InitGroup -> Cg ()
appendDecl cdecl = tell cdecl

appendDecls :: [C.InitGroup] -> Cg ()
appendDecls cdecls = tell cdecls

appendStm :: C.Stm -> Cg ()
appendStm cstm = tell cstm

appendStms :: [C.Stm] -> Cg ()
appendStms cstms = tell cstms

traceNest :: Int -> Cg a -> Cg a
traceNest d = local (\env -> env { nestdepth = nestdepth env + d })

traceCg :: Doc -> Cg ()
traceCg doc = do
    doTrace <- liftKZC $ asksFlags (testTraceFlag TraceCg)
    when doTrace $ do
        d <- asks nestdepth
        liftIO $ hPutDocLn stderr $ text "traceCg:" <+> indent d (align doc)
