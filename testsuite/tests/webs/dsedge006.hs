-- Roles: a phantom parameter changed by coerce, and a split type with a
-- phantom parameter used at two tags.
module Main (main) where

import Data.Coerce (coerce)

data Metres
data Feet

newtype Tagged t a = Tagged a
data Path t = Path [(Int, Int)]

walk :: Int -> Path t
walk n = Path [ (i, i + 1) | i <- [1 .. n] ]
{-# NOINLINE walk #-}

len :: Path t -> Int
len (Path ps) = go ps
  where go []           = 0
        go ((a, b) : r) = b - a + go r
{-# NOINLINE len #-}

retag :: Tagged Metres [(Int, Int)] -> Tagged Feet [(Int, Int)]
retag = coerce
{-# NOINLINE retag #-}

main :: IO ()
main = do
  print (len (walk 10 :: Path Metres) + len (walk 20 :: Path Feet))
  let Tagged ps = retag (Tagged [(1, 2), (3, 4)])
  print ps
