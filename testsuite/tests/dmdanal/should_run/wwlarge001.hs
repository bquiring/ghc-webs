-- A larger example for higher-order worker/wrapper
-- (-fworker-wrapper-function-results): text processing.  Cases marked [+]
-- should be split, [-] should not (the reason is given).
module Main (main) where

import WWLarge1A
import Data.Char (ord, isUpper, toLower)
import Data.List (foldl')

main :: IO ()
main = do
  let ws = words (concat (replicate 40 "The quick Brown fox jumps over the Lazy dog "))
      sc = mkScorer "haskell"
      sc2 = mkScorer "ghc"
      fmt = mkFormatter 3
      fmtA = fmt "ab"
  print (sum [ sc w False + sc2 w True | w <- ws ])
  print (length (concat [ fmtA n 'x' | n <- [1 .. 50] ]), fmt "xyz" 7 ' ')
  print ( withScorer (\s -> sum [ s w 0 | w <- take 30 ws ]) 7
        , withScorer (\s -> s "hello" 1 * 2) 11 )
  let (r, hs) = register (\t -> t "abc" 0) 3
  print (r, sum [ h (\a b -> length a + b) | h <- hs ])
  print (length (filter (runMatcher (mkMatcher "fox")) ws), runMatcher (mkMatcher "dog") "dog")
  print (walk (\f -> f 3 4) [1 .. 20], twice (+ 1) 5)
