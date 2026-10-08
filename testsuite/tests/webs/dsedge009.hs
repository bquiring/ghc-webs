-- Mutual recursion between a newtype and a data type.
module Main (main) where

newtype Forest = Forest [Tree]
data Tree = Node (Int, Int) Forest

grow :: Int -> Tree
grow 0 = Node (0, 0) (Forest [])
grow n = Node (n, n * 2) (Forest [ grow (n - 1), grow (max 0 (n - 2)) ])
{-# NOINLINE grow #-}

size :: Tree -> Int
size (Node (a, b) (Forest ts)) = a + b + sum (map size ts)
{-# NOINLINE size #-}

depth :: Tree -> Int
depth (Node _ (Forest [])) = 1
depth (Node _ (Forest ts)) = 1 + maximum (map depth ts)
{-# NOINLINE depth #-}

main :: IO ()
main = do
  let t = grow 12
  print (size t)
  print (depth t)
