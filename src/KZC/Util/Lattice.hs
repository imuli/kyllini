{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      :  KZC.Util.Lattice
-- Copyright   :  (c) 2015-2016 Drexel University
-- License     :  BSD-style
-- Maintainer  :  mainland@cs.drexel.edu

module KZC.Util.Lattice (
    Poset(..),

    Lattice(..),
    BoundedLattice(..),
    BranchLattice(..),

    Known(..),
    Bound(..)
  ) where

import qualified Prelude
import Prelude hiding ((<=))

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative (Applicative, (<*>), pure)
#endif /* !MIN_VERSION_base(4,8,0) */
import Control.Monad.State
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Test.QuickCheck
import Text.PrettyPrint.Mainland hiding (empty)

infix 4 <=

-- | A partially ordered set
class Eq a => Poset a where
    (<=) :: a -> a -> Bool

-- | A lattice
class Poset a => Lattice a where
    -- | Least upper bound, aka "join"
    lub :: a -> a -> a
    -- | Greatest lower bound, aka "meet"
    glb :: a -> a -> a

-- | A lattice with a greatest and least element
class Lattice a => BoundedLattice a where
    -- | Greatest element of the lattice
    top :: a
    -- | Least element of the lattice
    bot :: a

class Lattice a => BranchLattice a where
    -- | Branch upper bound, i.e., join for different control flow paths.
    bub :: a -> a -> a

instance Poset Bool where
    (<=) = (Prelude.==)

instance Poset Int where
    (<=) = (Prelude.<=)

instance Poset Integer where
    (<=) = (Prelude.<=)

instance Ord a => Poset (Set a) where
    (<=) = Set.isSubsetOf

instance (Ord k, Poset a) => Poset (Map k a) where
    m1 <= m2 = Map.keysSet m1 == Map.keysSet m2 &&
               Map.foldrWithKey f True m1
      where
        f :: k -> a -> Bool -> Bool
        f _ _ False = False
        f k v True  = v <= m2 Map.! k

instance Lattice Integer where
    i `lub` j = max i j
    i `glb` j = min i j

instance Ord a => Lattice (Set a) where
    s1 `lub` s2 = s1 `Set.union` s2
    s1 `glb` s2 = s1 `Set.intersection` s2

joinWith :: Ord k => (a -> a -> a) -> a -> Map k a -> Map k a -> Map k a
joinWith f dflt =
    Map.mergeWithKey (\_ a b -> Just (f a b)) (Map.map (f dflt)) (Map.map (f dflt))

instance (Ord k, BoundedLattice a) => Lattice (Map k a) where
    m1 `lub` m2 = joinWith lub bot m1 m2
    m1 `glb` m2 = joinWith glb bot m1 m2

instance (Ord k, BoundedLattice a, BranchLattice a) => BranchLattice (Map k a) where
    m1 `bub` m2 = joinWith bub bot m1 m2

-- | 'Known' allows us to construct a lattice from a partially ordered set by
-- adding top and bottom elements. The lattice is constructs /is not/ a valid
-- lattice if the type argument is a Lattice itself! Use 'Bound' to make a
-- lattice bounded.
data Known a = Unknown
             | Known a
             | Any
  deriving (Eq, Ord, Show)

instance Arbitrary a => Arbitrary (Known a) where
    arbitrary = oneof [pure Unknown, Known <$> arbitrary, pure Any]

instance Pretty a => Pretty (Known a) where
    ppr Unknown   = text "unknown"
    ppr (Known a) = ppr a
    ppr Any       = text "top"

instance Functor Known where
    fmap f x = x >>= return . f

instance Applicative Known where
    pure  = return
    (<*>) = ap

instance Monad Known where
    return = Known

    Unknown >>= _ = Unknown
    Known x >>= f = f x
    Any     >>= _ = Any

instance Poset a => Poset (Known a) where
    Unknown  <= _        = True
    _        <= Any      = True
    Known x1 <= Known x2 = x1 <= x2
    _        <= _        = False

instance Poset a => Lattice (Known a) where
    Unknown  `lub` x        = x
    x        `lub` Unknown  = x
    Any      `lub` _        = Any
    _        `lub` Any      = Any
    Known x1 `lub` Known x2
        | x1 <= x2          = Known x2
        | x2 <= x1          = Known x1
        | otherwise         = Any

    Unknown  `glb` _        = Unknown
    _        `glb` Unknown  = Unknown
    Any      `glb` x        = x
    x        `glb` Any      = x
    Known x1 `glb` Known x2
        | x1 <= x2          = Known x1
        | x2 <= x1          = Known x2
        | otherwise         = Unknown

instance Poset a => BoundedLattice (Known a) where
    top = Any
    bot = Unknown

-- | 'Bound' allows us to construct a bounded lattice from a lattice
data Bound a = UnknownB
             | KnownB a
             | AnyB
  deriving (Eq, Ord, Show)

instance Arbitrary a => Arbitrary (Bound a) where
    arbitrary = oneof [pure UnknownB, KnownB <$> arbitrary, pure AnyB]

instance Pretty a => Pretty (Bound a) where
    ppr UnknownB   = text "unknown"
    ppr (KnownB a) = ppr a
    ppr AnyB       = text "top"

instance Functor Bound where
    fmap f x = x >>= return . f

instance Applicative Bound where
    pure  = return
    (<*>) = ap

instance Monad Bound where
    return = KnownB

    UnknownB >>= _ = UnknownB
    KnownB x >>= f = f x
    AnyB     >>= _ = AnyB

instance Lattice a => Poset (Bound a) where
    UnknownB  <= _         = True
    _         <= AnyB      = True
    KnownB x1 <= KnownB x2 = x1 <= x2
    _         <= _         = False

instance Lattice a => Lattice (Bound a) where
    UnknownB  `lub` x         = x
    x         `lub` UnknownB  = x
    AnyB      `lub` _         = AnyB
    _         `lub` AnyB      = AnyB
    KnownB x1 `lub` KnownB x2 = KnownB (x1 `lub` x2)

    UnknownB  `glb` _         = UnknownB
    _         `glb` UnknownB  = UnknownB
    AnyB      `glb` x         = x
    x         `glb` AnyB      = x
    KnownB x1 `glb` KnownB x2 = KnownB (x1 `glb` x2)

instance Lattice a => BoundedLattice (Bound a) where
    top = AnyB
    bot = UnknownB
