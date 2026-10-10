-- A list built by recursion whose tail beyond what is consumed is poison.
-- (Deadness and strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

upTo :: Int -> Int -> [Int]
upTo n lim = if n == lim then poison "beyond the limit" else n : upTo (n + 1) lim
{-# NOINLINE upTo #-}

main :: IO ()
main = print (sum (take 10 (upTo 0 10)))
