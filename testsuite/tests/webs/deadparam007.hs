-- The functions flow into the imported 'map', so the web is exposed and
-- rejected.
module Main (main) where

k :: Int -> Int
k _ = 9
{-# NOINLINE k #-}

main :: IO ()
main = print (map k [1, 2, 3])
