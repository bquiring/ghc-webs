-- An infinite list consumed partially; every element past the prefix is
-- poison. (Deadness and strictness: the program must behave as it does
-- unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

stream :: Int -> [Int]
stream n = n : if n >= 5 then repeat (poison "past the prefix") else stream (n + 1)
{-# NOINLINE stream #-}

main :: IO ()
main = print (take 6 (stream 0))
