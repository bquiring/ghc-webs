-- A lazy let used only after a guard that returns early in every run.
-- (Deadness and strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

f :: [Int] -> Int
f xs = let s = poison "after the guard" + length xs in
       case xs of
         [] -> 0
         (x : _) | x >= 0 -> x
                 | otherwise -> s
{-# NOINLINE f #-}

main :: IO ()
main = print (map f [[], [1], [2, 3]])
