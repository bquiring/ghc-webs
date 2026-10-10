-- Mutual recursion where one function uses the parameter only under a branch
-- the run never takes: live, lazy. (Deadness and strictness: the program
-- must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

f, g :: Int -> Int -> Int
f 0 _ = 0
f n x = g (n - 1) x + 1
g 0 _ = 0
g n x = if n < 0 then x else f (n - 1) x * 2
{-# NOINLINE f #-}
{-# NOINLINE g #-}

apply :: (Int -> Int -> Int) -> Int -> Int
apply h n = h n (poison "rarely used")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply f 12, apply g 13)
