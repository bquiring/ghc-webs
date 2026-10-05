-- Super-beta inlining: only one function reaches the unknown calls in
-- 'apply', so it is inlined there, and the function parameter becomes dead.
module Main (main) where

apply :: (Int -> Int) -> Int -> Int
apply f n = f n + f (n + 1)
{-# NOINLINE apply #-}

sq :: Int -> Int
sq x = x * x + 1

main :: IO ()
main = print (sum [ apply sq i | i <- [1 .. 1000] ])
