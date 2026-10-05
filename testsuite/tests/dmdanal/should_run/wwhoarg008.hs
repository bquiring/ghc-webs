-- A recursive function that passes its local function to g at every
-- level, and recurses with the same g.
module Main (main) where

h :: ((Int -> Int -> Int) -> Int) -> Int -> Int
h g n | n <= 0    = 0
      | otherwise = let k = n * 3
                        f x y = (x * 1 + k) * (x - 1) + (x * 2 + k) * (x - 2) + (x * 3 + k) * (x - 3) + (x * 4 + k) * (x - 4) + (x * 5 + k) * (x - 5) + (x * 6 + k) * (x - 6) + (x * 7 + k) * (x - 7) + (x * 8 + k) * (x - 8) + (x * 9 + k) * (x - 9) + (x * 10 + k) * (x - 10) + (x * 11 + k) * (x - 11)   -- y dead
                    in g f + h g (n - 1) + f 1 1

main :: IO ()
main = print (h (\f -> f 2 0) 5, h (\f -> f 1 undefined + f 2 undefined) 8)
