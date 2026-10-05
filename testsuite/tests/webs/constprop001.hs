-- Constant arguments: every call of the web passes the same constant, so it
-- is substituted into the lambdas, and the parameter (now dead) is removed.
module Main (main) where

apply :: (Bool -> Int -> Int) -> Int -> Int
apply f n = f True n + f True (n + 1)
{-# NOINLINE apply #-}

addK, mulK :: Bool -> Int -> Int
addK b n = if b then n * 2 + 1 else n
mulK b n = if b then n * n else n - 1
{-# NOINLINE addK #-}
{-# NOINLINE mulK #-}

main :: IO ()
main = print (sum [ apply addK i + apply mulK i | i <- [1 .. 100] ])
