-- A tree traversal over a local type whose payload field is poison and only
-- the shape is used. (Deadness and strictness: the program must behave as it
-- does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

data Tree = Leaf | Node Tree Int Tree

mkTree :: Int -> Tree
mkTree 0 = Leaf
mkTree n = Node (mkTree (n - 1)) (poison "payload") (mkTree (n - 1))
{-# NOINLINE mkTree #-}

size :: Tree -> Int
size Leaf = 0
size (Node l _ r) = size l + 1 + size r
{-# NOINLINE size #-}

main :: IO ()
main = print (size (mkTree 8))
