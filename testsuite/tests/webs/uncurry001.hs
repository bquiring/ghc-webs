-- Uncurrying, the basic case: local two-argument functions passed to a
-- local higher-order function that always applies them to both arguments.
module Main (main) where

apply2 :: (Int -> Int -> Int) -> Int
apply2 f = f 1 2 + f 3 4
{-# NOINLINE apply2 #-}

add :: Int -> Int -> Int
add a b = a * 2 + b
{-# NOINLINE add #-}

sub :: Int -> Int -> Int
sub a b = a * 3 - b
{-# NOINLINE sub #-}

main :: IO ()
main = print (apply2 add, apply2 sub)
