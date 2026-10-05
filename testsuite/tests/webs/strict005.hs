-- Strict result fields: every caller of the web takes the result apart and
-- uses its first field, so the functions of the web evaluate that field
-- before returning the pair.
module Main (main) where

g :: Int -> Int
g n = n * 3
{-# NOINLINE g #-}

use :: (Int -> (Int, Int)) -> Int -> Int
use f n = case f n of (a, _) -> a + 1
{-# NOINLINE use #-}

p1, p2 :: Int -> (Int, Int)
p1 n = (g n, g (n + 1))
p2 n = (g (n * 2), n)
{-# NOINLINE p1 #-}
{-# NOINLINE p2 #-}

main :: IO ()
main = print (sum [ use p1 i + use p2 i | i <- [1 .. 1000] ])
