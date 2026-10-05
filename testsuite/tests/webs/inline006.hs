-- Pragmas: the only function reaching the unknown call has a NOINLINE
-- pragma, so it is not inlined.
module Main (main) where

apply :: (Int -> Int) -> Int -> Int
apply f n = f n + 1
{-# NOINLINE apply #-}

sq :: Int -> Int
sq x = x * x
{-# NOINLINE sq #-}

main :: IO ()
main = print (apply sq 4, apply sq 5)
