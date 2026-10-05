-- Rejections: different constants are passed, and different constants are
-- returned.
module Main (main) where

apply :: (Int -> Int) -> Int
apply f = f 3 + f 4
{-# NOINLINE apply #-}

check :: (Int -> Bool) -> Int -> Int
check f n = if f n then 1 else 0
{-# NOINLINE check #-}

sq :: Int -> Int
sq x = x * x
{-# NOINLINE sq #-}

yes, no :: Int -> Bool
yes n = n `seq` True
no n = n `seq` False
{-# NOINLINE yes #-}
{-# NOINLINE no #-}

main :: IO ()
main = print (apply sq, check yes 1 + check no 2)
