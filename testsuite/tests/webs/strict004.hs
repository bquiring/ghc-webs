-- Sharing: the argument is evaluated at the call, then again (already a
-- value) in the callee.  It must be computed once: the trace prints once per
-- call.  This test fails if the argument is duplicated.
module Main (main) where

import Debug.Trace

apply :: (Int -> Int) -> Int -> Int
apply f n = f (trace "eval" (n + 1))
{-# NOINLINE apply #-}

sq, dbl :: Int -> Int
sq x = x * x
dbl x = x + x
{-# NOINLINE sq #-}
{-# NOINLINE dbl #-}

main :: IO ()
main = print (apply sq 3, apply dbl 4)
