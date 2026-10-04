-- Dead-parameter elimination, the basic case: every function passed to
-- 'apply' ignores its argument, so the web is deleted.  The argument passed
-- in the first call would diverge if it were ever evaluated.
module Main (main) where

apply :: (Int -> Int) -> Int
apply f = f (error "argument evaluated") + f 1
{-# NOINLINE apply #-}

k1 :: Int -> Int
k1 _ = 5
{-# NOINLINE k1 #-}

k2 :: Int -> Int
k2 _ = 7
{-# NOINLINE k2 #-}

main :: IO ()
main = print (apply k1 + apply k2)
