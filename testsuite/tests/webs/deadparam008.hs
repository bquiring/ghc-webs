-- Several rounds: deleting the dead parameter of constB's web makes y dead
-- in callB, and then x dead in viaB.
module Main (main) where

callB :: (Int -> Int) -> Int -> Int
callB h y = h y
{-# NOINLINE callB #-}

constB :: Int -> Int
constB _ = 42
{-# NOINLINE constB #-}

callA :: (Int -> Int) -> Int
callA f = f 1
{-# NOINLINE callA #-}

viaB :: Int -> Int
viaB x = callB constB x
{-# NOINLINE viaB #-}

main :: IO ()
main = print (callA viaB)
