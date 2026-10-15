module Chunk001L (twice, helper, applyAll) where
twice :: (Int -> Int) -> Int -> Int
twice f x = f $ f x
{-# NOINLINE twice #-}
helper :: Int -> Int
helper = (* 3)
applyAll :: [Int -> Int] -> Int -> Int
applyAll fs x = foldr ($) x fs
