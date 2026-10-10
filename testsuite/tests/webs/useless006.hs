-- Note [Useless elimination], laziness: a dead unlifted result component
-- that is not ok for speculation keeps its evaluation.  No call uses the
-- second component, but computing it (a call of bad) raises an error once
-- the input is positive: the program must still fail there.
{-# LANGUAGE MagicHash, UnboxedTuples #-}
module Main (main) where

import GHC.Exts

bad :: Int -> Int#
bad n = if n > 0 then errorWithoutStackTrace "useless006: dead component evaluated" else 0#
{-# NOINLINE bad #-}

apply :: (Int -> (# Int, Int# #)) -> [Int] -> Int
apply f xs = sum [ case f x of (# a, _ #) -> a | x <- xs ]
{-# NOINLINE apply #-}

main :: IO ()
main = do
  print (apply (\x -> (# x + 1, bad (x - 20) #)) [1..10], apply (\x -> (# x * 2, 3# #)) [1..10])
  print (apply (\x -> (# x + 1, bad x #)) [1..10])
