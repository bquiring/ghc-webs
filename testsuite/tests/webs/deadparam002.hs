-- One function in the web uses its argument, so the web is rejected.
module Main (main) where

apply :: (Int -> Int) -> Int
apply f = f 10 + f 1
{-# NOINLINE apply #-}

k1 :: Int -> Int
k1 _ = 5
{-# NOINLINE k1 #-}

k2 :: Int -> Int
k2 x = x + 1
{-# NOINLINE k2 #-}

main :: IO ()
main = print (apply k1 + apply k2)
