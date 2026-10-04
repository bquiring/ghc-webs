-- Functions in a local list: the web appears in type arguments
-- ((:) @(Int -> Int -> Int)), which are rewritten consistently.
module Main (main) where

sumAll :: [Int -> Int -> Int] -> Int
sumAll []     = 0
sumAll (f:fs) = f 1 2 + sumAll fs
{-# NOINLINE sumAll #-}

add :: Int -> Int -> Int
add a b = a * 2 + b
{-# NOINLINE add #-}

mul :: Int -> Int -> Int
mul a b = a * b + 7
{-# NOINLINE mul #-}

main :: IO ()
main = print (sumAll [add, mul, add])
