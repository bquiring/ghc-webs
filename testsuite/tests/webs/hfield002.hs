-- See HField002A: an abstract type rebuilt in place, used through
-- unfoldings from the interface.
module Main (main) where

import HField002A

main :: IO ()
main = do
  print (useH (mkAdd 3) + useH (mkMul 4))
  print (sum [ useH (if even n then mkAdd n else mkMul n) | n <- [1 .. 10] ])
