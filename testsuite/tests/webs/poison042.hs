-- A field of a local type returned only in a dead result component; its
-- value is poison. (Deadness and strictness: the program must behave as it
-- does unoptimised.)
{-# LANGUAGE UnboxedTuples #-}
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

data T = T Int Int

build :: Int -> T
build n = T (n * 3) (poison "field in a dead component")
{-# NOINLINE build #-}

split :: (T -> (# Int, Int #)) -> [T] -> Int
split f ts = sum [ case f t of (# a, _ #) -> a | t <- ts ]
{-# NOINLINE split #-}

main :: IO ()
main = print (split (\(T a b) -> (# a, b #)) (map build [1 .. 10]))
