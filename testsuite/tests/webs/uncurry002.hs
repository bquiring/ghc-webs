-- A chain of three arguments, uncurried over two rounds into nested
-- unboxed tuples.
module Main (main) where

apply3 :: (Int -> Int -> Int -> Int) -> Int
apply3 f = f 1 2 3 + f 4 5 6
{-# NOINLINE apply3 #-}

g3 :: Int -> Int -> Int -> Int
g3 a b c = a * 100 + b * 10 + c
{-# NOINLINE g3 #-}

h3 :: Int -> Int -> Int -> Int
h3 a b c = a + b + c * 2
{-# NOINLINE h3 #-}

main :: IO ()
main = print (apply3 g3, apply3 h3)
