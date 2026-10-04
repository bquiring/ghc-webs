-- Laziness: a function in the web is forced with seq.  Deleting the
-- parameter would turn 'k' into the thunk 'undefined', and forcing it would
-- diverge.  The web must become a unit web instead, which keeps 'k' a lambda.
-- This test fails if that case is not handled.
module Main (main) where

force :: (Int -> Int) -> ()
force f = f `seq` ()
{-# NOINLINE force #-}

apply :: (Int -> Int) -> Int -> Int
apply f n = if n > 0 then f n else 0
{-# NOINLINE apply #-}

k :: Int -> Int
k _ = undefined
{-# NOINLINE k #-}

main :: IO ()
main = do
  print (force k)
  print (apply k 0)
