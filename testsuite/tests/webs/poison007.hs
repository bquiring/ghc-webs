-- A three-way cycle passing a dead parameter around. (Deadness and
-- strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

a, b, c :: Int -> Int -> Int
a 0 _ = 1
a n d = 1 + b (n - 1) d
b 0 _ = 2
b n d = 2 * c (n - 1) d
c 0 _ = 3
c n d = a (n - 1) d - 1
{-# NOINLINE a #-}
{-# NOINLINE b #-}
{-# NOINLINE c #-}

apply :: (Int -> Int -> Int) -> Int -> Int
apply f n = f n (poison "cycle parameter")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply a 9, apply b 10, apply c 11)
