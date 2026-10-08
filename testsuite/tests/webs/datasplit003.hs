-- A recursive local type: a tree that reaches the derived Show instance
-- (an instance is exported, so its dictionary keeps the original type) is
-- exposed; the tree that is only built and summed here gets a copy, whose
-- subtrees are the same copy.
module Main (main) where

data Tree = Leaf | Node Tree Int Tree
  deriving Show

build :: Int -> Int -> Tree
build lo hi
  | lo > hi   = Leaf
  | otherwise = let m = (lo + hi) `div` 2 in Node (build lo (m - 1)) m (build (m + 1) hi)
{-# NOINLINE build #-}

sumTree :: Tree -> Int
sumTree Leaf         = 0
sumTree (Node l x r) = sumTree l + x + sumTree r
{-# NOINLINE sumTree #-}

main :: IO ()
main = do
  print (sumTree (build 1 1000))
  print (Node Leaf 1 (Node Leaf 2 Leaf))
