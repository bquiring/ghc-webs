-- All three transformations together (arity raising, then dead parameters,
-- then uncurrying), with laziness checks for each.
module Main (main) where

import Debug.Trace

-- Arity raising: functions strict in a pair, and a shared pair argument
-- that must be evaluated once per call ("pair" traced twice in total)
usePair :: ((Int, Int) -> Int) -> Int -> Int
usePair f n = let p = trace "pair" (n, n * 2) in f p + f p
{-# NOINLINE usePair #-}

sumP :: (Int, Int) -> Int
sumP (a, b) = a + b
{-# NOINLINE sumP #-}

-- Dead parameters: functions that ignore their first argument; after
-- raising, the second argument of 'ignoreFirst' is also dead
ignoreFirst :: (Int -> Int -> Int) -> Int
ignoreFirst g = g (error "dead argument evaluated") 3 + g undefined 4
{-# NOINLINE ignoreFirst #-}

k1 :: Int -> Int -> Int
k1 _ y = y * 10
{-# NOINLINE k1 #-}

k2 :: Int -> Int -> Int
k2 _ y = y + 1
{-# NOINLINE k2 #-}

-- Uncurrying: a shared partial application ("arg" traced once per call)
apply2p :: (Int -> Int -> Int) -> Int -> Int
apply2p f n = let g = f (trace "arg" (n + 1)) in g 1 + g 2
{-# NOINLINE apply2p #-}

add :: Int -> Int -> Int
add a b = a * 2 + b
{-# NOINLINE add #-}

main :: IO ()
main = do
  print (usePair sumP 1, usePair sumP 2)
  print (ignoreFirst k1, ignoreFirst k2)
  print (apply2p add 1, apply2p add 2)
