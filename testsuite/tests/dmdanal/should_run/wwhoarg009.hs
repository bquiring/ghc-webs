-- Laziness for function arguments: the function passed to g is a lambda
-- written at the call, whose first argument is used only when n > 5 (lazy,
-- although demand analysis may mark it unboxable), and is undefined at the
-- call when n <= 5.  The split may drop the dead second argument but must
-- not unbox the first.
module Main (main) where

h :: ((Int -> Int -> Int) -> Int) -> Int -> Int
h g n = let k = sum [1 .. n]
        in g (\x y -> if n > 5 then (x * 1 + k) * (x - 1) + (x * 2 + k) * (x - 2) + (x * 3 + k) * (x - 3) + (x * 4 + k) * (x - 4) + (x * 5 + k) * (x - 5) + (x * 6 + k) * (x - 6) + (x * 7 + k) * (x - 7) + (x * 8 + k) * (x - 8) + (x * 9 + k) * (x - 9) + (x * 10 + k) * (x - 10) + (x * 11 + k) * (x - 11) + (x * 12 + k) * (x - 12) + (x * 13 + k) * (x - 13) + (x * 14 + k) * (x - 14) + (x * 15 + k) * (x - 15) + (x * 16 + k) * (x - 16) + (x * 17 + k) * (x - 17) + (x * 18 + k) * (x - 18) + (x * 19 + k) * (x - 19) + (x * 20 + k) * (x - 20) + (x * 21 + k) * (x - 21) else k) + k   -- y dead

main :: IO ()
main = print (h (\f -> f undefined 0) 3, h (\f -> f 2 undefined + f 3 0) 10, h (\f -> f 4 4) 2)
