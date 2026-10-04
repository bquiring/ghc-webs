-- Arity raising, the basic case: local functions strict in a pair, passed
-- to a local higher-order function.  They are raised to take (# Int, Int #).
module Main (main) where

useP :: ((Int, Int) -> Int) -> Int
useP f = f (1, 2) + f (3, 4)
{-# NOINLINE useP #-}

addP :: (Int, Int) -> Int
addP p = case p of (a, b) -> a + b
{-# NOINLINE addP #-}

mulP :: (Int, Int) -> Int
mulP (a, b) = a * b
{-# NOINLINE mulP #-}

main :: IO ()
main = print (useP addP, useP mulP)
