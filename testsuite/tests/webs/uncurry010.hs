-- A join point with two parameters, always jumped to saturated.
module Main (main) where

pick2 :: Bool -> Int -> Int
pick2 b n =
  let j x y = x * y + sum [x .. y]
  in if b then j n 30 else j 2 n
{-# NOINLINE pick2 #-}

main :: IO ()
main = print (pick2 True 3, pick2 False 40)
