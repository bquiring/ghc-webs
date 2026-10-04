-- Laziness: deleting the parameter turns 'k' into the thunk 'undefined'.
-- That is fine because 'k' is only ever applied, and only when n > 0, so the
-- thunk is never forced.  This test fails if the deleted function's body is
-- evaluated eagerly.
module Main (main) where

apply :: (Int -> Int) -> Int -> Int
apply f n = if n > 0 then f n else 0
{-# NOINLINE apply #-}

k :: Int -> Int
k _ = undefined
{-# NOINLINE k #-}

k2 :: Int -> Int
k2 _ = 3
{-# NOINLINE k2 #-}

main :: IO ()
main = print (apply k 0, apply k2 5)
