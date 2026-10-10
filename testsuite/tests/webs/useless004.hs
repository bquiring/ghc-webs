-- Note [Useless elimination], laziness: a dead unlifted argument that is
-- not ok for speculation keeps its evaluation.  The second argument of the
-- web's lambdas is dead, but computing it (a call of bad) raises an error:
-- the program must still fail, as it does unoptimised.
{-# LANGUAGE MagicHash #-}
module Main (main) where

import GHC.Exts

bad :: Int -> Int#
bad n = if n > 0 then errorWithoutStackTrace "useless004: dead argument evaluated" else 0#
{-# NOINLINE bad #-}

apply :: (Int -> Int# -> Int) -> Int -> Int
apply h n = h n (bad n)
{-# NOINLINE apply #-}

main :: IO ()
main = do
  print (apply (\a _ -> a + 1) 0, apply (\a _ -> a * 2) 0)
  print (apply (\a _ -> a + 1) 4, apply (\a _ -> a * 2) 5)
