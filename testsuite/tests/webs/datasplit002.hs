-- Constructors that a class never builds are dropped from its copy, with
-- their case alternatives: area1 is only ever given circles, so its copy of
-- Shape has one constructor; area2's class builds squares and triangles.
module Main (main) where

data Shape = Circle Double | Square Double | Tri Double Double

area1 :: Shape -> Double
area1 (Circle r) = 3 * r * r
area1 (Square s) = s * s
area1 (Tri b h)  = b * h / 2
{-# NOINLINE area1 #-}

area2 :: Shape -> Double
area2 (Circle r) = 3 * r * r
area2 (Square s) = s * s
area2 (Tri b h)  = b * h / 2
{-# NOINLINE area2 #-}

main :: IO ()
main = do
  print (area1 (Circle 1))
  print (area2 (Square 2) + area2 (Tri 3 4))
