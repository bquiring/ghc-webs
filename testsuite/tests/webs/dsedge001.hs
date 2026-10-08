-- Coercions: a local monomorphic newtype around a list of pairs.  The
-- newtype's axiom names the list itself (Note [Splitting newtypes]); values
-- go in and out of it through casts, and through coerce.
module Main (main) where

import Data.Coerce (coerce)

newtype Stack = Stack [(Int, Int)]

push :: Int -> Stack -> Stack
push n (Stack ps) = Stack ((n, n * n) : ps)
{-# NOINLINE push #-}

pushN :: Int -> Stack -> Stack
pushN 0 s = s
pushN n s = pushN (n - 1) (push n s)
{-# NOINLINE pushN #-}

total :: Stack -> Int
total (Stack ps) = go ps
  where go []            = 0
        go ((a, b) : r)  = a + b + go r
{-# NOINLINE total #-}

pairs :: Stack -> [(Int, Int)]
pairs = coerce
{-# NOINLINE pairs #-}

main :: IO ()
main = do
  let s = pushN 100 (Stack [])
  print (total s)
  print (take 3 (pairs s))
  print (total (coerce [(1 :: Int, 2 :: Int), (3, 4)]))
