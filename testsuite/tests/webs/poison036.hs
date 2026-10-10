-- An unboxed tuple result with a poison component no caller uses. (Deadness
-- and strictness: the program must behave as it does unoptimised.)
{-# LANGUAGE UnboxedTuples #-}
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

apply :: (Int -> (# Int, Int #)) -> [Int] -> Int
apply f xs = sum [ case f x of (# a, _ #) -> a | x <- xs ]
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply (\x -> (# x + 1, poison "component" #)) [1 .. 10])
