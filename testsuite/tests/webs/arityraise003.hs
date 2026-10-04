-- Laziness: a function strict in its pair only on some paths.  With
-- c = False it never forces the pair, so 'undefined' is fine.  The web must
-- be rejected.  This test fails if it is raised.
module Main (main) where

useU :: ((Int, Int) -> Int) -> (Int, Int) -> Int
useU f p = f p
{-# NOINLINE useU #-}

cond :: Bool -> (Int, Int) -> Int
cond c p = if c then fst p else 0
{-# NOINLINE cond #-}

main :: IO ()
main = print (useU (cond False) undefined, useU (cond True) (5, 6))
