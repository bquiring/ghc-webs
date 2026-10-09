-- Data.Complex: !a :+ !a, strict, used at Double (as nofib imaginary/x2n1).
-- The result, and that a strict field's error is raised on construction.
module Main (main) where

import Control.Exception
import Data.Complex

roots :: Int -> [Complex Double]
roots n = [ mkPolar 1 ((2 * pi) / fromIntegral k) ^ k | k <- [1 .. n] ]
{-# NOINLINE roots #-}

total :: [Complex Double] -> Complex Double
total []      = 0
total (z : r) = z + total r
{-# NOINLINE total #-}

reals :: [Complex Double] -> Double
reals []              = 0
reals ((x :+ _) : r)  = x + reals r
{-# NOINLINE reals #-}

main :: IO ()
main = do
  print (round (realPart (total (roots 1000))) :: Int)
  print (round (reals (roots 500)) :: Int)
  r <- try (evaluate (case (undefined :+ (1 :: Double)) of _ :+ y -> y))
  putStrLn (either (\(ErrorCall _) -> "diverged, as it must") show r)
