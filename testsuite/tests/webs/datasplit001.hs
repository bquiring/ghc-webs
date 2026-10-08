-- Splitting data types (Note [Splitting data types] in
-- GHC.WebCore.DataSplit).  The list that upto builds and total consumes
-- never meets base, so it gets its own copy of the list type; the list that
-- is printed reaches base's Show instance, so it is exposed and stays [].
module Main (main) where

upto :: Int -> Int -> [Int]
upto a b = if a > b then [] else a : upto (a + 1) b
{-# NOINLINE upto #-}

total :: [Int] -> Int
total []       = 0
total (x : xs) = x + total xs
{-# NOINLINE total #-}

main :: IO ()
main = do
  print (total (upto 1 100))
  print [1, 2, 3 :: Int]
