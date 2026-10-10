-- The partial application of mk does work (the trace); applyBoth, imported,
-- applies it twice.  The trace must appear once.
module Main (main) where

import Debug.Trace
import Boundary007A

mk :: Int -> Int -> Int
mk a = trace "boundary007: evaluated" (\b -> a * 10 + b)
{-# NOINLINE mk #-}

main :: IO ()
main = print (applyBoth mk 3 0)
