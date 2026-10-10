-- A lazy field that every match forces, but one construction is never
-- matched: evaluating fields at the producer would raise the poison.
-- (Deadness and strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

data T = T Int Int

sumT :: T -> Int
sumT (T a b) = a + b
{-# NOINLINE sumT #-}

pair :: Int -> (T, T)
pair n = (T n (n + 1), T n (poison "never matched"))
{-# NOINLINE pair #-}

main :: IO ()
main = print (sumT (fst (pair 5)))
