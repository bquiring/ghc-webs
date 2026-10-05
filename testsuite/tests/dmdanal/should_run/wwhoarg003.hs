-- Worker/wrapper through function arguments: two different local
-- functions are passed to g at the same position.  The second argument is
-- dead in both, so it is dropped; the first is lazy in f2 (and undefined
-- at a call that reaches only f2), so it is not unboxed.
module Main (main) where

h :: ((Int -> Int -> Int) -> Int) -> Bool -> Int -> Int
h g b n = let k = sum [1 .. n]
              f1 x y = (x * 1 + k) * (x - 1) + (x * 2 + k) * (x - 2) + (x * 3 + k) * (x - 3) + (x * 4 + k) * (x - 4) + (x * 5 + k) * (x - 5) + (x * 6 + k) * (x - 6) + (x * 7 + k) * (x - 7) + (x * 8 + k) * (x - 8) + (x * 9 + k) * (x - 9) + (x * 10 + k) * (x - 10) + (x * 11 + k) * (x - 11) + (x * 12 + k) * (x - 12) + (x * 13 + k) * (x - 13) + (x * 14 + k) * (x - 14) + (x * 15 + k) * (x - 15) + (x * 16 + k) * (x - 16) + (x * 17 + k) * (x - 17) + (x * 18 + k) * (x - 18) + (x * 19 + k) * (x - 19) + (x * 20 + k) * (x - 20) + (x * 21 + k) * (x - 21)                    -- y dead, x strict
              f2 x y = if k > 1000000 then x else k + 1   -- y dead, x lazy
          in (if b then g f1 else 0) + g f2 + f1 3 4 + f2 5 6

main :: IO ()
main = print ( h (\f -> f 1 2) True 10, h (\f -> f undefined 0) False 10
             , h (\f -> sum (map (\x -> f x x) [1 .. 3])) True 3 )
