-- A foldr-style fold with a combining function that ignores the accumulator;
-- the seed is poison. (Deadness and strictness: the program must behave as
-- it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

foldR :: (Int -> Int -> Int) -> Int -> [Int] -> Int
foldR _ z [] = z
foldR k z (x : xs) = k x (foldR k z xs)
{-# NOINLINE foldR #-}

main :: IO ()
main = print (foldR (\x _ -> x * 10) (poison "seed") [1, 2, 3], foldR (\x _ -> x + 1) (poison "seed2") [7])
