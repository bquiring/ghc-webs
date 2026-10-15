module Chunk004A (T(..), total) where

data T = T Int Int

-- A SPECIALISE rule of an exported overloaded function
total :: (Num a, Ord a) => [a] -> a
total = go 0
  where go acc []     = acc
        go acc (x:xs) = if x > 0 then go (acc + x) xs else go acc xs
{-# INLINABLE total #-}
{-# SPECIALISE total :: [Int] -> Int #-}
