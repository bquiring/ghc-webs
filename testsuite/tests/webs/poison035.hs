-- A dead non-terminating thunk: evaluating it would hang (the test would
-- time out). (Deadness and strictness: the program must behave as it does
-- unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

spin :: Int -> Int
spin n = spin (n + 1)
{-# NOINLINE spin #-}

apply :: (Int -> Int -> Int) -> Int
apply h = h 5 (spin 0)
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply (\a _ -> a * 4))
