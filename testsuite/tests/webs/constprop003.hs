-- Effects: the functions of the web return a constant, but the call must
-- still be evaluated: the trace prints once per call.  This test fails if a
-- call with a constant result is dropped.
module Main (main) where

import Debug.Trace

check :: (Int -> Bool) -> Int -> Int
check f n = case f n of
  True  -> n + 1
  False -> n - 1
{-# NOINLINE check #-}

noisy :: Int -> Bool
noisy n = trace ("called " ++ show n) n `seq` True
{-# NOINLINE noisy #-}

main :: IO ()
main = print (check noisy 1, check noisy 2)
