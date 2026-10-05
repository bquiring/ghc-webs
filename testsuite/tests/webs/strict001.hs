-- Strict arguments: every function reaching the unknown call in 'apply' is
-- strict in its argument, so the call evaluates the argument (g n) instead of
-- allocating a thunk for it.
module Main (main) where

g :: Int -> Int
g n = n * 2 + 1
{-# NOINLINE g #-}

apply :: (Int -> Int) -> Int -> Int
apply f n = f (g n)
{-# NOINLINE apply #-}

sq, inc :: Int -> Int
sq x = x * x
inc x = x + 1
{-# NOINLINE sq #-}
{-# NOINLINE inc #-}

main :: IO ()
main = print (sum [ apply sq i + apply inc i | i <- [1 .. 1000] ])
