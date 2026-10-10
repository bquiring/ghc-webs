-- A caller that forces the first field only in one branch: the field is
-- lazy, the poison in the other branch is never forced. (Deadness and
-- strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

apply :: (Int -> (Int, Int)) -> Int -> Int
apply f n = case f n of (a, b) -> if n > 0 then b else a
{-# NOINLINE apply #-}

mk :: Int -> (Int, Int)
mk n = (if n > 0 then poison "first field" else n, n + 1)
{-# NOINLINE mk #-}

main :: IO ()
main = print (apply mk 4, apply mk 0)
