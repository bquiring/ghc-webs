-- A parameter used only in a branch the run never takes: live but lazy.
-- Poison is passed; nothing may force it early. (Deadness and strictness:
-- the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

search :: Int -> Int -> Int -> Int
search n target fallback
  | n == target = n * 2
  | n > 1000    = fallback
  | otherwise   = search (n + 1) target fallback
{-# NOINLINE search #-}

apply :: (Int -> Int -> Int -> Int) -> Int
apply f = f 0 37 (poison "fallback")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply search)
