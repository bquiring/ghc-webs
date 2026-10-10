-- Must raise: building a strict field whose value is never read. (Deadness
-- and strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

data S = S Int !Int

mk :: Int -> S
mk n = S n (if n > 3 then errorWithoutStackTrace "poison028: strict field" else n)
{-# NOINLINE mk #-}

useS :: S -> Int
useS (S a _) = a
{-# NOINLINE useS #-}

main :: IO ()
main = print (map (useS . mk) [1 .. 5])
