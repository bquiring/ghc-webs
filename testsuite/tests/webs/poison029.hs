-- Must raise: a dead result component that is computed by an unlifted error.
-- (Deadness and strictness: the program must behave as it does unoptimised.)
{-# LANGUAGE MagicHash, UnboxedTuples #-}
module Main (main) where

import GHC.Exts

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

bad :: Int -> Int#
bad n = if n > 5 then errorWithoutStackTrace "poison029: unlifted component" else 0#
{-# NOINLINE bad #-}

apply :: (Int -> (# Int, Int# #)) -> [Int] -> Int
apply f xs = sum [ case f x of (# a, _ #) -> a | x <- xs ]
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply (\x -> (# x, bad x #)) [1 .. 10])
