-- Mutual recursion returning pairs whose second components are poison and
-- never read. (Deadness and strictness: the program must behave as it does
-- unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

p, q :: Int -> (Int, Int)
p 0 = (1, poison "p second")
p n = case q (n - 1) of (x, y) -> (x + 1, y)
q 0 = (2, poison "q second")
q n = case p (n - 1) of (x, y) -> (x * 2, y)
{-# NOINLINE p #-}
{-# NOINLINE q #-}

main :: IO ()
main = print (fst (p 10), fst (q 11))
