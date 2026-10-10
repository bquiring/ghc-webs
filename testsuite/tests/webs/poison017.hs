-- A local data type with a lazy field that is poison and never read.
-- (Deadness and strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

data T = T Int Int

build :: Int -> T
build n = T (n * 2) (poison "unread field")
{-# NOINLINE build #-}

useT :: T -> Int
useT (T a _) = a + 1
{-# NOINLINE useT #-}

main :: IO ()
main = print (sum (map (useT . build) [1 .. 10]))
