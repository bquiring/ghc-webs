-- Must raise: a bang pattern on an otherwise unused parameter. (Deadness and
-- strictness: the program must behave as it does unoptimised.)
{-# LANGUAGE BangPatterns #-}
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

f :: Int -> Int -> Int
f a !_ = a + 1
{-# NOINLINE f #-}

apply :: (Int -> Int -> Int) -> Int
apply h = h 1 2 + h 3 (errorWithoutStackTrace "poison027: forced by a bang")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply f)
