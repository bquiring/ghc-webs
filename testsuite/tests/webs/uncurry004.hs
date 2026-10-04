-- Laziness: work between the two lambdas.  The partial application g
-- shares "work", so it is traced once.  Uncurrying would move the work under
-- both lambdas and trace it twice, so the web must be rejected.
module Main (main) where

import Debug.Trace

apply2p :: (Int -> Int -> Int) -> Int -> Int
apply2p f n = let g = f n in g 1 + g 2
{-# NOINLINE apply2p #-}

mkAdder :: Int -> Int -> Int
mkAdder a = let t = trace "work" (a * 2) in \b -> t + b
{-# NOINLINE mkAdder #-}

main :: IO ()
main = print (apply2p mkAdder 5)
