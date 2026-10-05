-- Rejection: the only lambda of the web captures a local variable (k), so
-- it cannot be inlined at a call where k is not in scope.
module Main (main) where

apply :: (Int -> Int) -> Int -> Int
apply f n = f n + 1
{-# NOINLINE apply #-}

mk :: Int -> (Int -> Int)
mk k = \x -> x * k
{-# NOINLINE mk #-}

main :: IO ()
main = print (apply (mk 3) 4, apply (mk 5) 4)
