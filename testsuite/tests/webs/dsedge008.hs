-- A recursive newtype (Fix) over a local functor: the newtype's
-- representation mentions the newtype itself.
module Main (main) where

newtype Fix f = Fix (f (Fix f))

data ListF a r = NilF | ConsF a r

instance Functor (ListF a) where
  fmap _ NilF        = NilF
  fmap f (ConsF a r) = ConsF a (f r)

cata :: Functor f => (f b -> b) -> Fix f -> b
cata alg (Fix x) = alg (fmap (cata alg) x)
{-# NOINLINE cata #-}

fromTo :: Int -> Int -> Fix (ListF (Int, Int))
fromTo a b | a > b     = Fix NilF
           | otherwise = Fix (ConsF (a, a * a) (fromTo (a + 1) b))
{-# NOINLINE fromTo #-}

total :: ListF (Int, Int) Int -> Int
total NilF               = 0
total (ConsF (x, y) r)   = x + y + r

main :: IO ()
main = print (cata total (fromTo 1 100))
