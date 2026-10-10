-- Must raise: seq on an otherwise unused argument. (Deadness and strictness:
-- the program must behave as it does unoptimised.)
{-# LANGUAGE BangPatterns #-}
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

f :: Int -> Int -> Int
f a b = b `seq` a + 1
{-# NOINLINE f #-}

apply :: (Int -> Int -> Int) -> Int
apply h = h 1 2 + h 3 (errorWithoutStackTrace "poison026: forced by seq")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply f)
