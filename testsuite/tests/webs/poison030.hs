-- Must raise: a case on an otherwise dead variable forces it. (Deadness and
-- strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

f :: Int -> Int -> Int
f a b = case b of _ | b > 0 -> a + 1
                    | otherwise -> a + 2
{-# NOINLINE f #-}

apply :: (Int -> Int -> Int) -> Int
apply h = h 1 2 + h 3 (errorWithoutStackTrace "poison030: scrutinised")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply f)
