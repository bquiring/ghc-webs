-- Laziness inside unboxable fields: components that are errors or
-- infinite, never looked at; only the first components are consumed.
module Main (main) where

import Control.Exception

mk :: Int -> [(Int, Int)]
mk 0 = []
mk n = (n, error ("never " ++ show n)) : mk (n - 1)
{-# NOINLINE mk #-}

firsts :: [(Int, Int)] -> Int
firsts []           = 0
firsts ((a, _) : r) = a + firsts r
{-# NOINLINE firsts #-}

nats :: Int -> [(Int, [Int])]
nats n = (n, [n ..]) : nats (n + 1)
{-# NOINLINE nats #-}

main :: IO ()
main = do
  print (firsts (mk 100))
  print [ (a, take 2 xs) | (a, xs) <- take 3 (nats 7) ]
  r <- try (evaluate (sum [ b | (_, b) <- mk 3 ]))
  putStrLn (either (\(ErrorCall m) -> "caught: " ++ m) show r)
