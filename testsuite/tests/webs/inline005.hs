-- Scope: the inlined function mentions top-level bindings ('offset',
-- 'scale').  A copy of it may only be inlined into a top-level binding that
-- comes after them (top-level bindings are in dependency order).  Core Lint
-- fails if a copy mentions a binding that comes later.
module Main (main) where

apply :: (Int -> Int) -> Int -> Int
apply f n = f n + f (n * 2)
{-# NOINLINE apply #-}

offset :: Int
offset = length (show (12345 :: Int))
{-# NOINLINE offset #-}

scale :: Int
scale = length (show (99 :: Int))
{-# NOINLINE scale #-}

look :: Int -> Int
look x = x * scale + offset

main :: IO ()
main = print (sum [ apply look i | i <- [1 .. 100] ])
