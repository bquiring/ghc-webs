-- A where-bound helper whose value is poison, used under a condition that is
-- false. (Deadness and strictness: the program must behave as it does
-- unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

f :: Int -> Int -> Int
f a b = if a > b then helper else a + b
  where helper = poison "where helper" * 2
{-# NOINLINE f #-}

main :: IO ()
main = print (zipWith f [1 .. 5] [10 .. 14])
