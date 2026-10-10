-- A curried function with a dead middle parameter, partially applied and
-- shared. (Deadness and strictness: the program must behave as it does
-- unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

mk :: Int -> Int -> Int -> Int
mk a _ c = a * 100 + c
{-# NOINLINE mk #-}

apply :: (Int -> Int -> Int -> Int) -> Int
apply f = let g = f 7 (poison "middle") in g 1 + g 2
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply mk)
