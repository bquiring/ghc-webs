-- A local map-like loop over unknown functions that ignore their argument;
-- the list elements are poison. (Deadness and strictness: the program must
-- behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

mapL :: (Int -> Int) -> [Int] -> [Int]
mapL _ [] = []
mapL h (x : xs) = h x : mapL h xs
{-# NOINLINE mapL #-}

main :: IO ()
main = print (sum (mapL (\_ -> 3) [poison "e1", poison "e2", poison "e3"]),
              sum (mapL (\_ -> 4) [poison "e4"]))
