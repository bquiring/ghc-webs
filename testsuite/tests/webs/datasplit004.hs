-- Copies in coercions (Note [Copies in coercions]): the list inside the
-- local newtype Stack reaches pushN and sumS through casts.  The casts'
-- coercions get copies too, and so does the newtype (Note [Splitting
-- newtypes]): each copy of Stack has its own axiom, Stack_c ~R# List_c Int,
-- with a fresh list copy, so the list is split.
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
