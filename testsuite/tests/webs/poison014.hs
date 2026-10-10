-- Several lambdas in one web: one uses its second parameter, the others do
-- not; poison goes only to calls that reach the others. (Deadness and
-- strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

pick :: Int -> (Int -> Int -> Int)
pick 0 = \a b -> a + b
pick 1 = \a _ -> a * 2
pick _ = \a _ -> a - 1
{-# NOINLINE pick #-}

apply :: Int -> Int -> Int -> Int
apply k a b = pick k a b
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply 0 3 4, apply 1 5 (poison "pick 1"), apply 2 6 (poison "pick 2"))
