-- Coercions: coerce through a list of a newtype, and a list of pairs of a
-- newtype (lifting coercions over [] and (,)).
module Main (main) where

import Data.Coerce (coerce)

newtype Age = Age Int deriving Show

ages :: Int -> [(Age, Age)]
ages n = [ (Age i, Age (2 * i)) | i <- [1 .. n] ]
{-# NOINLINE ages #-}

asInts :: [(Age, Age)] -> [(Int, Int)]
asInts = coerce
{-# NOINLINE asInts #-}

sumAges :: [(Int, Int)] -> Int
sumAges []           = 0
sumAges ((a, b) : r) = a + b + sumAges r
{-# NOINLINE sumAges #-}

older :: [(Age, Age)] -> [(Age, Age)]
older ps = [ (Age (a + 1), Age b) | (Age a, Age b) <- ps ]
{-# NOINLINE older #-}

main :: IO ()
main = do
  print (sumAges (asInts (ages 100)))
  print (take 2 (older (ages 3)))
  print (sumAges (coerce (older (ages 10))))
