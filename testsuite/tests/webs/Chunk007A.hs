{-# LANGUAGE RankNTypes #-}
-- hledger-lib's generated classy lenses (Hledger.Data.Balancing): default
-- methods that are lenses into the class's record, and the record's own
-- instance in the same module
module Chunk007A (Opts (..), HasOpts (..), Lens', view, over, defOpts) where

import Data.Functor.Identity
import Data.Functor.Const

type Lens' s a = forall f. Functor f => (a -> f a) -> s -> f s

data Opts = Opts { _ignore :: Bool, _depth :: Int, _name :: String }

defOpts :: Opts
defOpts = Opts False 3 "opts"

class HasOpts c where
  opts :: Lens' c Opts
  ignore :: Lens' c Bool
  ignore = opts . ignore
  {-# INLINE ignore #-}
  depth :: Lens' c Int
  depth = opts . depth
  {-# INLINE depth #-}
  name :: Lens' c String
  name = opts . name
  {-# INLINE name #-}

-- The record's own instance: the default methods above go through it
instance HasOpts Opts where
  opts = id
  ignore f (Opts a b c) = fmap (\a' -> Opts a' b c) (f a)
  {-# INLINE ignore #-}
  depth f (Opts a b c) = fmap (\b' -> Opts a b' c) (f b)
  {-# INLINE depth #-}
  name f (Opts a b c) = fmap (\c' -> Opts a b c') (f c)
  {-# INLINE name #-}

view :: ((a -> Const a a) -> s -> Const a s) -> s -> a
view l s = getConst (l Const s)

over :: ((a -> Identity a) -> s -> Identity s) -> (a -> a) -> s -> s
over l f s = runIdentity (l (Identity . f) s)
