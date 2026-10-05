-- Higher-order worker/wrapper through calls ((Calls) in Note [Worker/wrapper
-- for function results]): g returns the result of h, which is split (its
-- returned function has a dead argument).  The calls of h in g's tails are
-- expanded with h's wrapper, so g is split as well, returning h's worker;
-- the partial applications p and q then call the worker directly.
module Main (main) where

h :: Int -> (Int -> Int -> Int)
h m = let k = sum [1 .. m]
      in \x _y -> (x * 1 + k) * (x - 1) + (x * 2 + k) * (x - 2) + (x * 3 + k) * (x - 3) + (x * 4 + k) * (x - 4) + (x * 5 + k) * (x - 5) + (x * 6 + k) * (x - 6) + (x * 7 + k) * (x - 7) + (x * 8 + k) * (x - 8) + (x * 9 + k) * (x - 9) + (x * 10 + k) * (x - 10) + (x * 11 + k) * (x - 11) + (x * 12 + k) * (x - 12) + (x * 13 + k) * (x - 13) + (x * 14 + k) * (x - 14) + (x * 15 + k) * (x - 15) + (x * 16 + k) * (x - 16) + (x * 17 + k) * (x - 17) + (x * 18 + k) * (x - 18) + (x * 19 + k) * (x - 19)      -- y dead

g :: Int -> Int -> (Int -> Int -> Int)
g n c = let base = sum [n .. n + c]
        in if c > 0 then h (base + c) else h base

run :: Int -> [Int] -> Int
run n xs = let p = g n 3
               q = g (n + 1) 0
           in sum (map (\x -> p x 0 + q x x) xs)

main :: IO ()
main = print (run 10 [1 .. 20], run 3 [5], g 2 1 4 undefined)
