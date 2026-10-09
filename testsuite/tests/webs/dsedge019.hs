-- Strict fields of a type variable (no wrapper: the worker is strict).  A
-- copy must be as strict as the original (Note [Copies keep strictness]):
-- building SP with an undefined field diverges, matching it does not need
-- to; the traces show each strict field evaluated once, when the cell is
-- built.
module Main (main) where

import Control.Exception
import Debug.Trace (trace)

data SP a = SP !a !a

mk :: Int -> [SP Int]
mk n = [ SP (trace ("field " ++ show i) i) (i * 2) | i <- [1 .. n] ]
{-# NOINLINE mk #-}

total :: [SP Int] -> Int
total []            = 0
total (SP a b : r)  = a + b + total r
{-# NOINLINE total #-}

firstOnly :: [SP Int] -> Int
firstOnly (SP a _ : _) = a
firstOnly []           = 0
{-# NOINLINE firstOnly #-}

main :: IO ()
main = do
  let xs = mk 3
  print (length xs)
  print (firstOnly xs)
  print (total xs)
  r <- try (evaluate (case SP (undefined :: Int) 1 of SP _ _ -> "matched"))
  putStrLn (either (\(ErrorCall _) -> "diverged, as it must") id r)
  r2 <- try (evaluate (length [SP (1 :: Int) undefined]))
  putStrLn (either (\(ErrorCall _) -> "diverged") show r2)
