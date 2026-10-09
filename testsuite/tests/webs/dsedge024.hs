-- Mutually recursive data types with one constructor each, holding pairs,
-- and a class whose methods recurse through both (dictionary arguments have
-- demands too: Note [Demands after flattening]); a knot through both types.
module Main (main) where

data A = A (Int, Int) B
data B = B Int (Int, Int) A

mkA :: Int -> A
mkA n = A (n, negate n) (mkB (n + 1))
{-# NOINLINE mkA #-}

mkB :: Int -> B
mkB n = B n (n, n * n) (mkA (n + 1))
{-# NOINLINE mkB #-}

class Walk t where
  walk :: Int -> t -> Int

instance Walk A where
  walk 0 (A (x, y) _) = x - y
  walk k (A (x, y) b) = x + y + walk (k - 1) b

instance Walk B where
  walk 0 (B m _ _)      = m
  walk k (B m (p, q) a) = m * p - q + walk (k - 1) a

total :: Walk t => [t] -> Int
total = go 0
  where go acc []       = acc
        go acc (t : ts) = let acc' = acc + walk 6 t in acc' `seq` go acc' ts
{-# NOINLINE total #-}

knot :: A
knot = a
  where a = A (1, 2) b
        b = B 3 (4, 5) a
{-# NOINLINE knot #-}

main :: IO ()
main = do
  print (walk 10 (mkA 1), walk 9 (mkB 1))
  print (total [mkA 0, mkA 5, knot])
  print (total [mkB 2, mkB 4])
