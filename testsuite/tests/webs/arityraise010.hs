-- The function flows into the imported 'map': exposed, so rejected.
module Main (main) where

addP :: (Int, Int) -> Int
addP (a, b) = a + b
{-# NOINLINE addP #-}

main :: IO ()
main = print (map addP [(1, 2), (3, 4)])
