-- Rejections: one function returns a pair it did not construct (a stored
-- pair), and a polymorphic function returns its argument's result type.
module Main (main) where

stored :: (Int, Int)
stored = (40, 2)
{-# NOINLINE stored #-}

use :: (Int -> (Int, Int)) -> Int -> Int
use f n = case f n of (a, b) -> a + b
{-# NOINLINE use #-}

fromStore, built :: Int -> (Int, Int)
fromStore n = if n > 0 then stored else (n, n)
built n = (n, n + 1)
{-# NOINLINE fromStore #-}
{-# NOINLINE built #-}

apply :: (a -> b) -> a -> b
apply f x = f x
{-# NOINLINE apply #-}

main :: IO ()
main = print (use fromStore 3, use built 4, fst (apply built 5))
