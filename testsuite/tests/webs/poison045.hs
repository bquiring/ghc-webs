-- A field forced by every match, built in a lazy let used on only one
-- branch: the construction's value is not certainly evaluated. (Deadness and
-- strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

data T = T Int Int

f :: Int -> Int
f n = let t = T n (poison "lazily built") in if n > 100 then (case t of T a b -> a + b) else n
{-# NOINLINE f #-}

main :: IO ()
main = print (map f [1, 2, 3])
