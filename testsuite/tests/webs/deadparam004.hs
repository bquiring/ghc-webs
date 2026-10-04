-- Functions stored in a local list: the web appears in a type argument
-- ((:) @(Int -> Int)), where polymorphic code could force it, so the web
-- becomes a unit web.
module Main (main) where

sumApply :: [Int -> Int] -> Int
sumApply []     = 0
sumApply (f:fs) = f 0 + sumApply fs
{-# NOINLINE sumApply #-}

c1 :: Int -> Int
c1 _ = 1
{-# NOINLINE c1 #-}

c2 :: Int -> Int
c2 _ = 2
{-# NOINLINE c2 #-}

main :: IO ()
main = print (sumApply [c1, c2])
