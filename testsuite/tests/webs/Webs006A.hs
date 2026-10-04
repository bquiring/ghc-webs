{-# OPTIONS_GHC -fexpose-all-unfoldings #-}
-- The library module for webs006.  'g' is not exported, but f's unfolding
-- (a vanilla one, exposed by -fexpose-all-unfoldings) mentions it, so g
-- reaches the interface file.
module Webs006A ( f ) where

f :: Int -> Int
f x = g 20 x + 1

g :: Int -> Int -> Int
g n x | n == 0    = x
      | otherwise = x + g (n - 1) x
{-# NOINLINE g #-}
