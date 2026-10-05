-- Two function parameters, each given a local function with a dead
-- argument; for g2 the function is the second argument of its call.  Both
-- parameters are split (one after the other).
module Main (main) where

h :: ((Int -> Int -> Int) -> Int) -> (Int -> (Int -> Int -> Int) -> Int) -> Int -> Int
h g1 g2 n = let k = sum [1 .. n]
                f1 x y = (x * 1 + k) * (x - 1) + (x * 2 + k) * (x - 2) + (x * 3 + k) * (x - 3) + (x * 4 + k) * (x - 4) + (x * 5 + k) * (x - 5) + (x * 6 + k) * (x - 6) + (x * 7 + k) * (x - 7) + (x * 8 + k) * (x - 8) + (x * 9 + k) * (x - 9) + (x * 10 + k) * (x - 10) + (x * 11 + k) * (x - 11) + (x * 12 + k) * (x - 12) + (x * 13 + k) * (x - 13) + (x * 14 + k) * (x - 14) + (x * 15 + k) * (x - 15) + (x * 16 + k) * (x - 16) + (x * 17 + k) * (x - 17) + (x * 18 + k) * (x - 18) + (x * 19 + k) * (x - 19) + (x * 20 + k) * (x - 20) + (x * 21 + k) * (x - 21)             -- y dead
                f2 x y = (y * 1 + k) * (y - 1) + (y * 2 + k) * (y - 2) + (y * 3 + k) * (y - 3) + (y * 4 + k) * (y - 4) + (y * 5 + k) * (y - 5) + (y * 6 + k) * (y - 6) + (y * 7 + k) * (y - 7) + (y * 8 + k) * (y - 8) + (y * 9 + k) * (y - 9) + (y * 10 + k) * (y - 10) + (y * 11 + k) * (y - 11) + (y * 12 + k) * (y - 12) + (y * 13 + k) * (y - 13) + (y * 14 + k) * (y - 14) + (y * 15 + k) * (y - 15) + (y * 16 + k) * (y - 16) + (y * 17 + k) * (y - 17) + (y * 18 + k) * (y - 18) + (y * 19 + k) * (y - 19) + (y * 20 + k) * (y - 20) + (y * 21 + k) * (y - 21)             -- x dead
            in g1 f1 + g2 n f2 + g2 (n + 1) f2 + f1 1 1 + f2 2 2

main :: IO ()
main = print ( h (\f -> f 1 2) (\m f -> f m m) 10
             , h (\f -> f 3 undefined) (\m f -> f undefined m) 5 )
