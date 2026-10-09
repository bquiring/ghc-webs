-- Polymorphic recursion (nested data types): each level holds pairs of the
-- previous level's elements, so the recursive field's type is not the type
-- it is in.  Nest ends; PS has one constructor and never ends.
module Main (main) where

data Nest a = NNil | NCons a (Nest (a, a))

build :: a -> Int -> Nest a
build _ 0 = NNil
build x n = NCons x (build (x, x) (n - 1))
{-# NOINLINE build #-}

sizeN :: (a -> Int) -> Nest a -> Int
sizeN _ NNil        = 0
sizeN f (NCons x r) = f x + sizeN (\(p, q) -> f p + f q) r
{-# NOINLINE sizeN #-}

data PS a = PS a (PS (a, a))

psFrom :: a -> PS a
psFrom x = PS x (psFrom (x, x))
{-# NOINLINE psFrom #-}

sumPS :: Int -> (a -> Int) -> PS a -> Int
sumPS 0 f (PS x _) = f x
sumPS k f (PS x r) = f x + sumPS (k - 1) (\(p, q) -> f p + f q) r
{-# NOINLINE sumPS #-}

main :: IO ()
main = do
  print (sizeN id (build 3 6))
  print (sumPS 8 id (psFrom 1))
  print (sumPS 5 (\(a, b) -> a * b) (psFrom (2, 3)))
