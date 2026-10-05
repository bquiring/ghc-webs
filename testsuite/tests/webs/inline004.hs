-- Sharing: the inlined function uses its argument twice; the argument is
-- let-bound, so it is computed once (the trace prints once per call).  A
-- polymorphic function that also receives it calls it at another type, so
-- that call is not inlined.
module Main (main) where

import Debug.Trace

apply :: (Int -> Int) -> Int -> Int
apply f n = f (trace "arg" (n + 1))
{-# NOINLINE apply #-}

applyP :: (a -> a) -> a -> a
applyP f x = f (f x)
{-# NOINLINE applyP #-}

twice :: Int -> Int
twice x = x + x

main :: IO ()
main = print (apply twice 1, apply twice 2, applyP twice 3)
