-- Result raising: every function reaching the unknown calls in 'use'
-- constructs its pair, so the web returns the components in an unboxed tuple.
module Main (main) where

g :: Int -> Int
g n = n * 3 + 1
{-# NOINLINE g #-}

use :: (Int -> (Int, Int)) -> Int -> Int
use f n = case f n of (a, b) -> a + b
{-# NOINLINE use #-}

p1, p2 :: Int -> (Int, Int)
p1 n = (n + 1, g n)
p2 n = if n > 500 then (g n, n) else (n, 0)
{-# NOINLINE p1 #-}
{-# NOINLINE p2 #-}

main :: IO ()
main = print (sum [ use p1 i + use p2 i | i <- [1 .. 1000] ])
