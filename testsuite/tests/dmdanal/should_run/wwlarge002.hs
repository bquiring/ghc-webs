-- A larger example for higher-order worker/wrapper
-- (-fworker-wrapper-function-results): numerics.  Cases marked [+] should be
-- split, [-] should not (the reason is given).
module Main (main) where

import WWLarge2A
import Data.List (foldl')

main :: IO ()
main = do
  let integ = mkIntegrator 40
      fs = [ sin, cos, \x -> x * x, exp . negate ]
  print (round (1000 * sum [ integ f 0 b 1e-6 | f <- fs, b <- [1, 2, 3] ]) :: Int)
  let observer f = foldl' (\acc i -> acc + f (fromIntegral i / 10) 0.1 0) 0 [1 .. 50 :: Int]
  print (round (simulate observer 2.0) :: Int, round (simulate (\f -> f 1 1 1) 3.0) :: Int)
  print (round (experiment (\d -> d (\f -> f 0.3 0.2 0)) 1.5) :: Int)
  print (round (mkPoly 3 2 0) :: Int)
  print (applyN (\f -> f 2 3) (5 :: Int), round (applyN (\f -> f 2 3) (0.5 :: Double)) :: Int)
  print (round (scaleAll (\f -> f 3 0) 1.5) :: Int)
