-- Nested pairs: a deep component is poison and never read. (Deadness and
-- strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

nest :: Int -> ((Int, Int), (Int, Int))
nest n = ((n, poison "deep a"), (poison "deep b", n * 3))
{-# NOINLINE nest #-}

useNest :: ((Int, Int), (Int, Int)) -> Int
useNest ((a, _), (_, d)) = a + d
{-# NOINLINE useNest #-}

main :: IO ()
main = print (sum (map (useNest . nest) [1 .. 5]))
