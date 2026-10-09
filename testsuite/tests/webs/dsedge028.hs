-- Trees: a finite one, folded strictly with an accumulator pair, and an
-- infinite one whose leaf is matched but never built (its copy keeps only
-- the node: one constructor, recursive twice), consumed to a depth.
module Main (main) where

data T = Leaf | Node (Int, Int) T T

build :: Int -> Int -> T
build lo hi
  | lo > hi   = Leaf
  | otherwise = let m = (lo + hi) `div` 2
                in Node (m, m * m) (build lo (m - 1)) (build (m + 1) hi)
{-# NOINLINE build #-}

foldT :: (Int, Int) -> T -> (Int, Int)
foldT acc Leaf                 = acc
foldT (s, q) (Node (a, b) l r) = case foldT (s + a, q + b) l of
  (s', q') -> s' `seq` q' `seq` foldT (s', q') r
{-# NOINLINE foldT #-}

data IT = IN (Int, Int) IT IT | IL

full :: Int -> IT
full n = IN (n, n `mod` 3) (full (2 * n)) (full (2 * n + 1))
{-# NOINLINE full #-}

sumDepth :: Int -> IT -> Int
sumDepth 0 _               = 0
sumDepth _ IL              = 0
sumDepth d (IN (a, b) l r) = a + b + sumDepth (d - 1) l + sumDepth (d - 1) r
{-# NOINLINE sumDepth #-}

leftmost :: Int -> IT -> (Int, Int)
leftmost _ IL            = (0, 0)
leftmost 0 (IN p _ _)    = p
leftmost d (IN _ l _)    = leftmost (d - 1) l
{-# NOINLINE leftmost #-}

main :: IO ()
main = do
  print (foldT (0, 0) (build 1 100))
  print (sumDepth 10 (full 1))
  print (leftmost 20 (full 3))
