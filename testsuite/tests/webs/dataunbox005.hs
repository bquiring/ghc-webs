-- Note [Unboxable fields]: each pair of the local list is passed whole to
-- addP, which is strict in it and uses it unboxed (its demand signature),
-- so the pairs are still unpacked into the cons cells; the call gets a
-- rebuilt pair that worker/wrapper takes apart again.
module Main (main) where

mk :: Int -> Int -> [(Int, Int)]
mk a b = if a > b then [] else (a, a * a) : mk (a + 1) b
{-# NOINLINE mk #-}

addP :: (Int, Int) -> Int
addP (a, b) = a * 2 + b
{-# NOINLINE addP #-}

sumL :: [(Int, Int)] -> Int
sumL []      = 0
sumL (p : r) = addP p + sumL r
{-# NOINLINE sumL #-}

main :: IO ()
main = print (sumL (mk 1 1000))
