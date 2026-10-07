-- Strict result fields through a tail call: the result of f is the result
-- of 'via', and every caller of via forces both fields.  So the functions
-- that reach f (mk, mk2) evaluate both fields.  Without tail contexts
-- (Note [Web strictness fixpoints]) the call of f is an unknown context.
module Main (main) where

mk, mk2 :: Int -> (Int, Int)
mk n = (n + 1, n * 2)
mk2 n = (n - 1, n)
{-# NOINLINE mk #-}
{-# NOINLINE mk2 #-}

via :: (Int -> (Int, Int)) -> Int -> (Int, Int)
via f n = f (n + 1)
{-# NOINLINE via #-}

use :: (Int -> (Int, Int)) -> Int -> Int
use f n = case via f n of (a, b) -> a + b
{-# NOINLINE use #-}

main :: IO ()
main = print (use mk 3 + use mk2 4)
