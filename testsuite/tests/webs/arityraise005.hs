-- Laziness and sharing: the caller passes the same pair (a traced thunk)
-- twice.  It must be evaluated once per call of useTwice ("arg" is traced
-- twice in total).  This test fails if raising duplicates the argument.
module Main (main) where

import Debug.Trace

useTwice :: ((Int, Int) -> Int) -> Int -> Int
useTwice f n = let p = trace "arg" (n, n + 1) in f p + f p
{-# NOINLINE useTwice #-}

addP :: (Int, Int) -> Int
addP (a, b) = a + b
{-# NOINLINE addP #-}

mulP :: (Int, Int) -> Int
mulP (a, b) = a * b
{-# NOINLINE mulP #-}

main :: IO ()
main = print (useTwice addP 3, useTwice mulP 3)
