-- Laziness: as strict011, but one caller of via ignores the first field,
-- and a function that reaches f returns a diverging first field.  Only the
-- second field is strict through the tail call, so the first must not be
-- evaluated.  This test fails if tail contexts ignore a caller.
module Main (main) where

mk, bad :: Int -> (Int, Int)
mk n = (n + 1, n * 2)
bad n = (error "strict012: field evaluated", n)
{-# NOINLINE mk #-}
{-# NOINLINE bad #-}

via :: (Int -> (Int, Int)) -> Int -> (Int, Int)
via f n = f (n + 1)
{-# NOINLINE via #-}

use, useSnd :: (Int -> (Int, Int)) -> Int -> Int
use f n = case via f n of (a, b) -> a + b
useSnd f n = case via f n of (_, b) -> b
{-# NOINLINE use #-}
{-# NOINLINE useSnd #-}

main :: IO ()
main = print (use mk 3, useSnd bad 5)
