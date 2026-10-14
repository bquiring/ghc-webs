-- Flattening rewrites the demands on a flattened field's components
-- (fix_sd in GHC.WebCore.DataFlatten).  A function-typed component that is
-- only evaluated (seq) has the demand 1A: absent below the evaluation.
-- Taking it apart as a call gave an absent call cardinality, which mkCall
-- rejects (ASSERT failed in GHC.Types.Demand, building futhark's
-- Language.Futhark.TypeChecker.Terms).
module Main (main) where

mk :: Int -> ((Int -> Int, Int), Int)
mk n = ((\x -> x + n, n * 2), n)
{-# NOINLINE mk #-}

use :: ((Int -> Int, Int), Int) -> Int
use ((f, m), k) = f `seq` (m + k)
{-# NOINLINE use #-}

apply :: ((Int -> Int, Int), Int) -> Int
apply ((f, m), k) = f m + k
{-# NOINLINE apply #-}

main :: IO ()
main = print (sum [ use (mk i) + apply (mk i) | i <- [1 .. 100] ])
