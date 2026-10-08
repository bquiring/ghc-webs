-- Sharing: one pair referenced from many cells, and a shared expensive
-- component that must be evaluated once (the trace appears once).
module Main (main) where

import Debug.Trace (trace)

copies :: (Int, Int) -> Int -> [(Int, Int)]
copies p n = replicate n p
{-# NOINLINE copies #-}

total :: [(Int, Int)] -> Int
total []           = 0
total ((a, b) : r) = a + b + total r
{-# NOINLINE total #-}

expensive :: Int -> Int
expensive n = trace "expensive" (sum [1 .. n])
{-# NOINLINE expensive #-}

main :: IO ()
main = do
  let shared = (expensive 1000, 1)
  print (total (copies shared 500))
  print (total [ (x, x) | x <- [1 .. 100] ])
