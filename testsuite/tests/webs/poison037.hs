-- A boxed product result across recursion: the second field is poison and
-- never read by any caller. (Deadness and strictness: the program must
-- behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

stats :: [Int] -> (Int, Int)
stats [] = (0, poison "stats second")
stats (x : xs) = case stats xs of (s, m) -> (s + x, max m x)
{-# NOINLINE stats #-}

apply :: ([Int] -> (Int, Int)) -> Int
apply f = case f [1 .. 10] of (s, _) -> s
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply stats)
