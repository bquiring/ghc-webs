-- unsafeCoerce (a UnivCo) between lists of pairs of types with the same
-- representation.
module Main (main) where

import Unsafe.Coerce (unsafeCoerce)

ints :: Int -> [(Int, Int)]
ints n = [ (i, -i) | i <- [1 .. n] ]
{-# NOINLINE ints #-}

asWords :: [(Int, Int)] -> [(Word, Word)]
asWords = unsafeCoerce
{-# NOINLINE asWords #-}

firsts :: [(Word, Word)] -> Word
firsts []           = 0
firsts ((a, _) : r) = a + firsts r
{-# NOINLINE firsts #-}

main :: IO ()
main = print (firsts (asWords (ints 100)))
