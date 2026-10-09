-- Splitting can leave a recursive type with one constructor: lists only ever
-- built with (:), infinite or cyclic, so their copies drop [].  Their pairs
-- are unboxable, and strict consumers give the copies product demands;
-- rewriting those must not unfold the recursion (Note [Demands after
-- flattening]: dsedge011 made the compiler loop this way).
module Main (main) where

gen :: Int -> [(Int, Int)]
gen n = (n, n * n) : gen (n + 1)
{-# NOINLINE gen #-}

cyc :: [(Int, Int)]
cyc = (1, 2) : (3, 4) : (5, 6) : cyc
{-# NOINLINE cyc #-}

grid :: Int -> [[(Int, Int)]]
grid i = row 0 : grid (i + 1)
  where row c = (i, c) : row (c + 1)
{-# NOINLINE grid #-}

sumTo :: Int -> [(Int, Int)] -> Int
sumTo 0 _            = 0
sumTo k ((a, b) : r) = a + b + sumTo (k - 1) r
{-# NOINLINE sumTo #-}

walk :: Int -> (Int, Int) -> [(Int, Int)] -> (Int, Int)
walk 0 acc    _            = acc
walk k (s, p) ((a, b) : r) = walk (k - 1) (s + a, (p + b) `mod` 1000) r
{-# NOINLINE walk #-}

-- the k-th pair (from 0), its components forced
force :: Int -> [(Int, Int)] -> (Int, Int)
force 0 ((a, b) : _) = a `seq` b `seq` (a, b)
force k (_ : r)      = force (k - 1) r
{-# NOINLINE force #-}

row :: Int -> [[(Int, Int)]] -> [(Int, Int)]
row 0 (r : _)  = r
row k (_ : rs) = row (k - 1) rs
{-# NOINLINE row #-}

sums :: Int -> [[(Int, Int)]] -> [Int]
sums 0 _        = []
sums k (r : rs) = sumTo 3 r : sums (k - 1) rs
{-# NOINLINE sums #-}

main :: IO ()
main = do
  print (sumTo 10 (gen 1))
  case walk 1000 (0, 0) (gen 3) of (s, p) -> s `seq` p `seq` print (s, p)
  print (sumTo 7 cyc, force 100 cyc)
  print (sums 3 (grid 2))
  print (force 5 (row 4 (grid 0)))
