-- The recursion one level down: T = (Int, (T, Int) ->{w} Int).  w's lambdas
-- take a pair apart, and its first component is a T, taken apart too:
-- nested unboxing of the pair reaches T, whose field is w again.
module Main (main) where

data T = T Int ((T, Int) -> Int)

f1 :: (T, Int) -> Int
f1 (T a g, k)
  | a <= 0    = k
  | otherwise = a * k + g (T (a - 1) f2, k + 1)
{-# NOINLINE f1 #-}

f2 :: (T, Int) -> Int
f2 (T a g, k)
  | a <= 0    = negate k
  | otherwise = a + g (T (a - 1) f1, k * 2 `mod` 101)
{-# NOINLINE f2 #-}

main :: IO ()
main = do
  print (f1 (T 8 f2, 1), f2 (T 8 f1, 1))
  print (f1 (T 0 f1, 0) + f2 (T 3 f2, 3) + f1 (T 7 f2, 7))
