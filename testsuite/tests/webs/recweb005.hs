-- recweb001 through a newtype and a pair: N = N (Int, N ->{w} Int).  The
-- newtype's representation mentions the newtype through the function's
-- argument.
module Main (main) where

newtype N = N (Int, N -> Int)

nf :: N -> Int
nf (N (a, g))
  | a <= 0    = 7
  | otherwise = a + g (N (a - 1, ng))
{-# NOINLINE nf #-}

ng :: N -> Int
ng (N (a, g))
  | a <= 0    = 11
  | otherwise = a * 2 + g (N (a - 1, nf))
{-# NOINLINE ng #-}

main :: IO ()
main = do
  print (nf (N (10, ng)), ng (N (10, nf)))
  print (nf (N (1, nf)) + ng (N (3, ng)) + nf (N (5, ng)))
