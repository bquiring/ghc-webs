-- The pair parameter is used both in a case and as a whole, so the raised
-- function must re-box it.
module Main (main) where

useP :: ((Int, Int) -> Int) -> Int
useP f = f (1, 2) + f (3, 4)
{-# NOINLINE useP #-}

sumPair :: (Int, Int) -> Int
sumPair (a, b) = a + b
{-# NOINLINE sumPair #-}

both :: (Int, Int) -> Int
both p = case p of (a, _) -> a * 100 + sumPair p
{-# NOINLINE both #-}

main :: IO ()
main = print (useP both)
