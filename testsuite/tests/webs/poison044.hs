-- A recursive local list whose element field is forced by every consumer,
-- and whose spine past the consumed prefix is poison. (Deadness and
-- strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

data L = Nil | Cons Int L

mk :: Int -> L
mk 0 = Cons 0 (poison "past the end")
mk n = Cons n (mk (n - 1))
{-# NOINLINE mk #-}

takeSum :: Int -> L -> Int
takeSum 0 _ = 0
takeSum _ Nil = 0
takeSum k (Cons x r) = x + takeSum (k - 1) r
{-# NOINLINE takeSum #-}

main :: IO ()
main = print (takeSum 5 (mk 10))
