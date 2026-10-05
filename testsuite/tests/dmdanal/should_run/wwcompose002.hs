-- As wwcompose001, with h in another module: its wrapper comes from the
-- interface file.
module Main (main) where

import WWComposeA

g :: Int -> Int -> (Int -> Int -> Int)
g n c = let base = sum [n .. n + c]
        in if c > 0 then h (base + c) else h base

run :: Int -> [Int] -> Int
run n xs = let p = g n 3
               q = g (n + 1) 0
           in sum (map (\x -> p x 0 + q x x) xs)

main :: IO ()
main = print (run 10 [1 .. 20], run 3 [5], g 2 1 4 undefined)
