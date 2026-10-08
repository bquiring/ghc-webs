-- Copies in coercions (Note [Copies in coercions]): the list inside the
-- local newtype Stack reaches pushN and sumS through casts.  The casts'
-- coercions get copies too.  But the newtype's axiom, Stack ~R# [Int],
-- names the list type itself (not through a type argument), and axioms keep
-- their original types, so the list is still exposed: it needs copies of the
-- newtype (with their own axioms), not yet done.  The dump shows it.
module Main (main) where

newtype Stack = Stack [Int]

pushN :: Int -> Stack -> Stack
pushN 0 s          = s
pushN n (Stack xs) = pushN (n - 1) (Stack (n : xs))
{-# NOINLINE pushN #-}

sumS :: Stack -> Int
sumS (Stack xs) = go xs
  where go []       = 0
        go (y : ys) = y + go ys
{-# NOINLINE sumS #-}

main :: IO ()
main = print (sumS (pushN 100 (Stack [])))
