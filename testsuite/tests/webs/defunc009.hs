-- Whole arities (Note [Defunctionalising whole arities]): the folds' lambdas
-- all take two arguments, always together, so the outer web and the web it
-- returns are defunctionalised at once, with one constructor per lambda and
-- a two-argument apply.  The inner web is reported as absorbed.
module Main (main) where

data Tree a = Node a [Tree a]

foldTree :: (a -> [b] -> b) -> Tree a -> b
foldTree f (Node a cs) = f a (map (foldTree f) cs)
{-# NOINLINE foldTree #-}

size, depth :: Tree Int -> Int
size  = foldTree (\_ ns -> 1 + sum ns)
depth = foldTree (\_ ds -> 1 + maximum (0 : ds))

total :: Int -> Tree Int -> Int
total k = foldTree (\a xs -> k * a + sum xs)

build :: Int -> Tree Int
build 0 = Node 0 []
build n = Node n [build (n - 1), build (n `div` 2)]

main :: IO ()
main = do
  let t = build 12
  print (size t, depth t, total 3 t)
