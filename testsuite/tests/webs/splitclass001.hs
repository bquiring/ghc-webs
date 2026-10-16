module Main (main) where

import SplitClass001A

main :: IO ()
main = do
  print (total [ Box i (i + 1) | i <- [1 .. 100] ])
  print (total [ Circle i | i <- [1 .. 50] ])
