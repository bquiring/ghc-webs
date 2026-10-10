-- Note [Useless elimination]: a dead parameter of a join point, whose
-- arguments are an error and a loop.  The join point loses it; neither
-- argument is evaluated.
module Main (main) where

f :: Int -> Int -> Int
f x y =
  let j :: Int -> Int -> Int
      j a _ = a * 3
      {-# NOINLINE j #-}
  in if x > y then j x (errorWithoutStackTrace "useless011: join argument")
              else j y (let loop k = loop (k + 1) :: Int in loop x)
{-# NOINLINE f #-}

main :: IO ()
main = print (f 5 2, f 1 9)
