-- A field of a local type read only to be passed to a dead parameter of
-- unknown functions: dead through the web (useless elimination, Note [Dead
-- fields of internal types]); its value is poison. (Deadness and strictness:
-- the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

data T = T Int Int

build :: Int -> T
build n = T (n + 1) (poison "field passed to a dead parameter")
{-# NOINLINE build #-}

use :: (Int -> Int -> Int) -> T -> Int
use h (T a b) = h a b
{-# NOINLINE use #-}

main :: IO ()
main = print (use (\x _ -> x * 2) (build 3), use (\x _ -> x + 1) (build 4))
