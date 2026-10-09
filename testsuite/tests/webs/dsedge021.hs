-- Strict fields of concrete types (unpacked by GHC, so they have a wrapper
-- and are not split), mixed with lazy ones and with a strict polymorphic
-- record, in local lists; seq on a cell with a bottom strict field.
module Main (main) where

import Control.Exception

data V = V !Double !Double
data R a = R { rx :: !a, ry :: a }

vs :: Int -> [V]
vs n = [ V (fromIntegral i) (fromIntegral (i * i)) | i <- [1 .. n] ]
{-# NOINLINE vs #-}

norm1 :: [V] -> Double
norm1 []          = 0
norm1 (V a b : r) = abs a + abs b + norm1 r
{-# NOINLINE norm1 #-}

rs :: Int -> [R Int]
rs n = [ R i (if i == 3 then error "lazy field" else i) | i <- [1 .. n] ]
{-# NOINLINE rs #-}

sumX :: [R Int] -> Int
sumX []          = 0
sumX (R x _ : r) = x + sumX r
{-# NOINLINE sumX #-}

main :: IO ()
main = do
  print (norm1 (vs 100))
  print (sumX (rs 10))
  r <- try (evaluate (R (undefined :: Int) 1 `seq` "built"))
  putStrLn (either (\(ErrorCall _) -> "diverged, as it must") id r)
  r2 <- try (evaluate (R (1 :: Int) undefined `seq` "built"))
  putStrLn (either (\(ErrorCall _) -> "diverged") id r2)
