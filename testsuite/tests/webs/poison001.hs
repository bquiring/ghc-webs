-- Self recursion: an accumulator that the loop passes along but never reads;
-- its initial value is poison. (Deadness and strictness: the program must
-- behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

loop :: Int -> Int -> Int -> Int
loop n acc dead = if n == 0 then acc else loop (n - 1) (acc + n) (dead + 1)
{-# NOINLINE loop #-}

apply :: (Int -> Int -> Int -> Int) -> Int -> Int
apply f n = f n 0 (poison "dead accumulator")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply loop 100)
