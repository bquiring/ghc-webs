module Unused001L where
twice :: (Int -> Int) -> Int -> Int
twice f x = f (f x)
{-# NOINLINE twice #-}
unusedHO :: (Int -> Int) -> Int -> Int
unusedHO f x = f x + 1
{-# NOINLINE unusedHO #-}
helper :: Int -> Int
helper = (* 3)
