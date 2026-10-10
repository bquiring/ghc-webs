-- A tail-recursive loop with a dead counter and a dead flag; their initial
-- values and increments are poison. (Deadness and strictness: the program
-- must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

count :: Int -> Int -> Int -> Bool -> Int
count n acc c b = if n == 0 then acc else count (n - 1) (acc + 2) (c + poison "increment") (not b)
{-# NOINLINE count #-}

main :: IO ()
main = print (count 10 0 (poison "counter") (poison "flag"))
