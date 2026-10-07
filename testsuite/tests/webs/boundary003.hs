-- Sharing: a partial application of a local function is eta-expanded at an
-- argument of an imported function only if its arguments are trivial.
-- Here the argument is a traced expression; expanding would evaluate it
-- once per element.  The trace must appear once.
module Main (main) where

import Debug.Trace

add :: Int -> Int -> Int
add a b = a * 2 + b
{-# NOINLINE add #-}

run :: Int -> [Int] -> [Int]
run k xs = let f a b = add a b + k
           in map (f (trace "boundary003: evaluated" (k + 1))) xs ++ [f k k]
{-# NOINLINE run #-}

main :: IO ()
main = print (run 3 [1, 2, 3])
