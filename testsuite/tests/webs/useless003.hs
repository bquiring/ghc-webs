-- Note [Useless elimination]: laziness.  The dead second components are
-- errors, and the dead argument diverges; dropping them must not change
-- what the program prints (nothing is evaluated that was not).
module Main (main) where

apply :: (Int -> (Int, Int)) -> [Int] -> Int
apply f xs = sum [ case f x of (a, _) -> a | x <- xs ]
{-# NOINLINE apply #-}

ignore :: (Int -> Int -> Int) -> Int -> Int
ignore h n = h n (let loop k = loop (k + 1) in loop n)
{-# NOINLINE ignore #-}

main :: IO ()
main = do
  print (apply (\x -> (x + 1, error "useless003: forced")) [1..10])
  print (ignore (\a _ -> a * 2) 4, ignore (\a _ -> a + 1) 5)
