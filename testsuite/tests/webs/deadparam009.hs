-- A join point whose parameter only becomes dead after earlier rounds:
-- once constB's web is deleted, y is dead in callB, then x is dead in the
-- join point j.  GHC's own absence analysis cannot see this, because x is
-- passed to callB.  Deleting the join point's parameter reduces its join
-- arity, and its jumps must stay saturated (checked by Core Lint).
module Main (main) where

callB :: (Int -> Int) -> Int -> Int
callB h y = h y
{-# NOINLINE callB #-}

constB :: Int -> Int
constB _ = 42
{-# NOINLINE constB #-}

pick :: Bool -> Int -> Int
pick b n =
  let j x = callB constB x + sum [n .. n + 50]
  in if b then j (n + 1) else j (n * 2)
{-# NOINLINE pick #-}

main :: IO ()
main = print (pick True 1, pick False 2)
