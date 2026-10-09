-- Recursive data types with one constructor (every value infinite or a
-- knot), with unboxable pairs in their fields: a stream, a record pointing
-- at itself, and recursion through a pair, R = R (Int, R), each level's pair
-- holding the next level.  Strict consumers give them product demands,
-- which must be rewritten without unfolding the types.
module Main (main) where

data Stream = S (Int, Int) Stream

from :: Int -> Stream
from n = S (n, n + 1) (from (n + 2))
{-# NOINLINE from #-}

sumS :: Int -> Stream -> Int
sumS 0 _            = 0
sumS k (S (a, b) r) = a * b + sumS (k - 1) r
{-# NOINLINE sumS #-}

zipS :: Stream -> Stream -> Stream
zipS (S (a, b) r) (S (c, d) q) = S (a + c, b * d) (zipS r q)
{-# NOINLINE zipS #-}

data Chain = Chain { cval :: (Int, Int), cnext :: Chain, cskip :: Chain }

ring :: Int -> Chain
ring n = first
  where first  = Chain (1, n) second third
        second = Chain (2, n * 2) third first
        third  = Chain (3, n * 3) first second
{-# NOINLINE ring #-}

hops :: Int -> Chain -> (Int, Int)
hops 0 c = cval c
hops k c | even k    = hops (k - 1) (cnext c)
         | otherwise = hops (k - 1) (cskip c)
{-# NOINLINE hops #-}

data R = R (Int, R)

countR :: Int -> R
countR n = R (n, countR (n * 2))
{-# NOINLINE countR #-}

depth :: Int -> R -> Int
depth 0 (R (a, _)) = a
depth k (R (a, r)) = a + depth (k - 1) r
{-# NOINLINE depth #-}

main :: IO ()
main = do
  print (sumS 20 (from 0))
  print (sumS 5 (zipS (from 1) (from 10)))
  print (hops 10 (ring 7), hops 11 (ring 7))
  print (depth 10 (countR 1))
