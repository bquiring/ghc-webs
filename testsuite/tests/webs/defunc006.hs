-- A polymorphic higher-order function used at two types: twiceP's
-- parameter's arrow is  a -> a  inside it, and  Int -> Int  and
-- String -> String  at its callers.  The data type D a b covers all three.
module Main (main) where

twiceP :: (a -> a) -> a -> a
twiceP f x = f (f x)
{-# NOINLINE twiceP #-}

main :: IO ()
main = print (twiceP (\y -> y * 3) (2 :: Int), twiceP (\s -> 'x' : s) "y")
