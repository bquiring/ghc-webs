-- Strict in every branch but one, which returns early: the parameter is
-- lazy; poison only reaches the early-return call. (Deadness and strictness:
-- the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

go :: Int -> Int -> Int
go 0 _ = 0
go n k = k + go (n - 1) k
{-# NOINLINE go #-}

apply :: (Int -> Int -> Int) -> Int
apply f = f 0 (poison "k on the early return") + f 3 4
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply go)
