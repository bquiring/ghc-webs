-- An exposed web: the functions are passed to 'map' (another module), so
-- their web is exposed and is not transformed.
module Main (main) where

sq, inc :: Int -> Int
sq x = x * x
inc x = x + 1
{-# NOINLINE sq #-}
{-# NOINLINE inc #-}

main :: IO ()
main = print (sum (map sq [1 .. 10 :: Int]) + sum (map inc [1 .. 10]))
