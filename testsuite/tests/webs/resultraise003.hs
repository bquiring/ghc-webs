-- Result raising through join points: the pair is constructed in several
-- branches, after a join point.  The join point's result type changes too.
module Main (main) where

use :: (Int -> (Int, Int)) -> Int -> Int
use f n = case f n of (a, b) -> a - b
{-# NOINLINE use #-}

step :: Int -> (Int, Int)
step n =
  let k = n * n + 7
      fin x = if x > 3 then (x, k) else (k, x)
      {-# NOINLINE fin #-}
  in case n `mod` 3 of
       0 -> fin (n + 1)
       1 -> fin (n * 2)
       _ -> (n, n)
{-# NOINLINE step #-}

main :: IO ()
main = print (sum [ use step i | i <- [1 .. 100] ])
