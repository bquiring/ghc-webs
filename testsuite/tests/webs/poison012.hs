-- Continuation passing: continuations that ignore their argument; the value
-- passed is poison. (Deadness and strictness: the program must behave as it
-- does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

withValue :: Int -> (Int -> Int -> r) -> r
withValue n k = k n (poison "continuation argument")
{-# NOINLINE withValue #-}

main :: IO ()
main = print (withValue 5 (\a _ -> a + 1), withValue 6 (\a _ -> a * 3))
