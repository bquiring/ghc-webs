-- Laziness: the functions are strict in the pair but never use its first
-- component, which is a traced thunk.  Raising passes the components as
-- they are, so "x" must never be traced.  This test fails if raising
-- evaluates the components.
module Main (main) where

import Debug.Trace

useFirst :: ((Int, Int) -> Int) -> Int -> Int
useFirst f n = f (trace "x" n, n + 1)
{-# NOINLINE useFirst #-}

sndTimes10 :: (Int, Int) -> Int
sndTimes10 p = case p of (_, b) -> b * 10
{-# NOINLINE sndTimes10 #-}

sndPlus1 :: (Int, Int) -> Int
sndPlus1 p = case p of (_, b) -> b + 1
{-# NOINLINE sndPlus1 #-}

main :: IO ()
main = print (useFirst sndTimes10 1, useFirst sndPlus1 2)
