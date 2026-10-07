-- Laziness and sharing (Note [Defunctionalisation]).  The lambdas'
-- free variables become constructor fields, which stay lazy: 'big' is
-- evaluated once (one trace) although the function is called three times,
-- and 'bad' is never evaluated, because the body never forces it.
module Main (main) where

import Debug.Trace ( trace )

thrice :: (Int -> Int) -> Int -> Int
thrice f x = f (f (f x))
{-# NOINLINE thrice #-}

n :: Int
n = length (show (1234567 :: Int))
{-# NOINLINE n #-}

main :: IO ()
main = do
  let big = trace "big" (sum [1 .. n])
      bad = error "defunc002: bad evaluated" :: Int
  print (thrice (\y -> y + big) 1)
  print (thrice (\y -> if y > 1000 then bad else y * 2) 1)
