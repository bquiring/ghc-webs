-- Laziness: a partial application is shared, and called twice.  Its
-- argument must be evaluated once ("arg" is traced once per call of
-- apply2p).  This test fails if eta-expanding the partial application
-- duplicates the argument.
module Main (main) where

import Debug.Trace

apply2p :: (Int -> Int -> Int) -> Int -> Int
apply2p f n = let g = f (trace "arg" (n * 2)) in g 1 + g 2
{-# NOINLINE apply2p #-}

add :: Int -> Int -> Int
add a b = a * 2 + b
{-# NOINLINE add #-}

mul :: Int -> Int -> Int
mul a b = a * b + 1
{-# NOINLINE mul #-}

main :: IO ()
main = print (apply2p add 5, apply2p mul 5)
