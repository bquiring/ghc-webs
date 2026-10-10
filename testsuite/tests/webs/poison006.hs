-- Mutual recursion (even/odd) passing a parameter neither uses. (Deadness
-- and strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

isEven, isOdd :: Int -> Int -> Bool
isEven 0 _ = True
isEven n d = isOdd (n - 1) d
isOdd 0 _ = False
isOdd n d = isEven (n - 1) d
{-# NOINLINE isEven #-}
{-# NOINLINE isOdd #-}

apply :: (Int -> Int -> Bool) -> Int -> Bool
apply f n = f n (poison "even/odd parameter")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply isEven 10, apply isOdd 7)
