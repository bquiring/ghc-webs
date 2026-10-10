-- A list of pairs whose second components are poison; only the first
-- components are consumed. (Deadness and strictness: the program must behave
-- as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

firsts :: [(Int, Int)] -> Int
firsts [] = 0
firsts ((a, _) : r) = a + firsts r
{-# NOINLINE firsts #-}

main :: IO ()
main = print (firsts [ (i, poison ("second " ++ show i)) | i <- [1 .. 20] ])
