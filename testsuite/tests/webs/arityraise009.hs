-- A record with a strict, unpacked field: its components are Int# and Int.
module Main (main) where

data P = P {-# UNPACK #-} !Int Int

useR :: (P -> Int) -> Int
useR f = f (P 1 2) + f (P 3 4)
{-# NOINLINE useR #-}

sumR :: P -> Int
sumR (P a b) = a + b
{-# NOINLINE sumR #-}

diffR :: P -> Int
diffR (P a b) = b - a
{-# NOINLINE diffR #-}

main :: IO ()
main = print (useR sumR, useR diffR)
