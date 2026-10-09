-- Note [Dead fields] in GHC.WebCore.DataFlatten.  The accumulator's second
-- field only flows, through arithmetic, back into the same field of the next
-- accumulator: no match ever reads it, so it is dropped, with its
-- arithmetic.  The final result reads only the first field (as x2n1's sum
-- of complex numbers reads only the real part).  Q's second field holds an
-- error and is dead too: dropping it never forces it.  R's second field is
-- passed to a function, so it is live and kept.
module Main (main) where

data P = P Double Double

step :: P -> Int -> P
step (P re im) n = P (re + fromIntegral n) (im * 2 + re)
{-# NOINLINE step #-}

run :: Int -> Double
run k = case go (P 0 1) 1 of P re _ -> re
  where
    go acc n | n > k     = acc
             | otherwise = go (step acc n) (n + 1)

data Q = Q Int Int

walk :: Q -> Int -> Q
walk (Q a b) n = Q (a + n) (b + error "dead field forced")
{-# NOINLINE walk #-}

runQ :: Int -> Int
runQ k = case go (Q 0 0) 1 of Q a _ -> a
  where
    go acc n | n > k     = acc
             | otherwise = go (walk acc n) (n + 1)

data R = R Int Int

use :: Int -> Int
use x = x * 3
{-# NOINLINE use #-}

runR :: Int -> Int
runR k = go (R 0 1) 1
  where
    go (R a b) n | n > k     = a + use b
                 | otherwise = go (R (a + n) (b + 1)) (n + 1)

main :: IO ()
main = do
  print (run 1000)
  print (runQ 1000)
  print (runR 1000)
