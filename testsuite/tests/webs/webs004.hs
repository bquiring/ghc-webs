-- Boundary case: functions and data structures of functions that cross a
-- module boundary.  Everything that flows into or out of Webs004A must end up
-- in an exposed web class (E in -ddump-webs-summary); functions that only
-- flow between local functions must not.
module Main (main) where

import Webs004A

-- Passed to an imported function: exposed
square :: Int -> Int
square x = x * x
{-# NOINLINE square #-}

-- Stored in an imported data constructor: exposed
triple :: Int -> Int
triple x = 3 * x
{-# NOINLINE triple #-}

-- Stored in a list passed to an imported function: exposed
addTen :: Int -> Int
addTen x = x + 10
{-# NOINLINE addTen #-}

-- Takes a function out of an imported data structure and calls it: the
-- call's web is exposed, but useOps's own arrows are local
useOps :: Ops -> Int -> Int
useOps ops x = opFun ops (x + 1)
{-# NOINLINE useOps #-}

-- Purely local higher-order function: its argument's web is local, and is
-- shared with halve, the only function passed to it
localApply :: (Int -> Int) -> Int -> Int
localApply f x = f (f x)
{-# NOINLINE localApply #-}

halve :: Int -> Int
halve x = x `div` 2
{-# NOINLINE halve #-}

main :: IO ()
main = do
  print (twice square 3)
  print (applyOp (Ops "triple" triple) 5)
  print (applyAll [addTen, square] 2)
  print (useOps (mkOps "neg" negate) 4)
  print (localApply halve 40)
