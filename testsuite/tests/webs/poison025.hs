-- A local product type (split and unboxed by data splitting) with a poison
-- field never used. (Deadness and strictness: the program must behave as it
-- does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

data P = P Int Int

mkP :: Int -> P
mkP n = P (n + 1) (poison "P second")
{-# NOINLINE mkP #-}

addP :: P -> P -> Int
addP (P a _) (P c _) = a + c
{-# NOINLINE addP #-}

main :: IO ()
main = print (sum [ addP (mkP i) (mkP (i * 2)) | i <- [1 .. 10] ])
