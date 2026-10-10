-- Note [Useless elimination]: a let used only in the argument of a dead
-- parameter is dead too, and goes; its right-hand side traces and is never
-- evaluated, before or after.  The live let is evaluated once.
module Main (main) where

import Debug.Trace

apply :: (Int -> Int -> Int) -> Int -> Int
apply h n =
  let dead = trace "useless013: dead let" (n * 100)
      live = trace "useless013: live let" (n + 1)
  in h live dead + h live (dead + 1)
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply (\a _ -> a * 2) 4, apply (\a _ -> a + 1) 5)
