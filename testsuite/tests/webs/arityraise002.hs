-- Laziness: one function of the web ignores its pair.  Raising would make
-- the caller take the argument apart, forcing 'undefined'.  The web must be
-- rejected (lazy in its argument).  This test fails if it is raised.
module Main (main) where

useU :: ((Int, Int) -> Int) -> (Int, Int) -> Int
useU f p = f p
{-# NOINLINE useU #-}

lazyF :: (Int, Int) -> Int
lazyF _ = 0
{-# NOINLINE lazyF #-}

strictF :: (Int, Int) -> Int
strictF (a, b) = a + b
{-# NOINLINE strictF #-}

main :: IO ()
main = print (useU lazyF undefined, useU strictF (1, 2))
