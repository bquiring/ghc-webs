-- Partial applications passed to the imported 'map': the inner web is
-- exposed, but the outer web is local, so it is uncurried and the partial
-- application is eta-expanded.
module Main (main) where

apply2m :: (Int -> Int -> Int) -> [Int]
apply2m f = map (f 10) [1, 2, 3] ++ [f 1 2]
{-# NOINLINE apply2m #-}

add :: Int -> Int -> Int
add a b = a * 2 + b
{-# NOINLINE add #-}

main :: IO ()
main = print (apply2m add)
