-- See HField005A: a type that mentions a rebuilt type is rebuilt too.
module Main (main) where

import HField005A

kids :: Int -> Str Int
kids n | n > 1     = Two (One (n `div` 2)) (One (n - 1))
       | otherwise = Zero

walk :: Int -> Zipper Int Int -> [Int]
walk 0 z = [hole z]
walk k z = hole z : case down kids z of
  Just z' -> walk (k - 1) z' ++ maybe [] (\u -> [hole u]) (up z')
  Nothing -> []

main :: IO ()
main = do
  let z = zipper kids 100
  print (walk 6 z)
  print (fromZipper z)
  print (fmap fromZipper (down kids z >>= down kids >>= up))
