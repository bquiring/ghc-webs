-- Self recursion returning a pair: the second component is poison in the
-- base case and never read. (Deadness and strictness: the program must
-- behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

walk :: Int -> (Int, Int)
walk 0 = (0, poison "base second")
walk n = case walk (n - 1) of (a, b) -> (a + n, b + 1)
{-# NOINLINE walk #-}

main :: IO ()
main = print (fst (walk 50))
