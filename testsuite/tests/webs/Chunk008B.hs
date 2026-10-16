module Chunk008B (scale) where

-- scale's unfolding mentions helper, which is not exported: in the chunk
-- {Chunk008A, Chunk008B} it moves to the merged module, Chunk008A, which
-- Chunk008C (in another chunk) does not import
helper :: Int -> [Int] -> Int
helper k xs = sum [ k * x + length (show x) | x <- xs ]
{-# NOINLINE helper #-}

scale :: Int -> [Int] -> Int
scale k xs = helper (k + 1) xs
{-# INLINE scale #-}
