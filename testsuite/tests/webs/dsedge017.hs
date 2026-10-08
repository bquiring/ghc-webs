-- Knots: a list of pairs defined in terms of itself, and a pair whose
-- component refers to the list it is in; must not be forced early.
module Main (main) where

walk :: Int -> [(Int, Int)]
walk n = ps
  where ps = (0, n) : [ (a + 1, b) | (a, b) <- ps ]
{-# NOINLINE walk #-}

selfLen :: Int -> [(Int, Int)]
selfLen n = xs
  where xs = [ (i, length xs) | i <- [1 .. n] ]
{-# NOINLINE selfLen #-}

total :: [(Int, Int)] -> Int
total []           = 0
total ((a, b) : r) = a + b + total r
{-# NOINLINE total #-}

main :: IO ()
main = do
  print (take 4 (walk 9))
  print (total (take 50 (walk 1)))
  print (total (selfLen 10))
