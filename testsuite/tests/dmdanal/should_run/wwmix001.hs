-- Mix: the ordinary split (g's strict Int argument is unboxed) together
-- with the split through g's returned function (dead y, strict x).
module Main (main) where

g :: Int -> (Int -> Int -> Int)
g n = let k = sum [1 .. n]
          f x y = (x * 1 + k) * (x - 1)
               + (x * 2 + k) * (x - 2)
               + (x * 3 + k) * (x - 3)
               + (x * 4 + k) * (x - 4)
               + (x * 5 + k) * (x - 5)
               + (x * 6 + k) * (x - 6)
               + (x * 7 + k) * (x - 7)
               + (x * 8 + k) * (x - 8)
               + (x * 9 + k) * (x - 9)
               + (x * 10 + k) * (x - 10)
               + (x * 11 + k) * (x - 11)
               + (x * 12 + k) * (x - 12)
               + (x * 13 + k) * (x - 13)
               + (x * 14 + k) * (x - 14)
               + (x * 15 + k) * (x - 15)
               + (x * 16 + k) * (x - 16)
               + (x * 17 + k) * (x - 17)
               + (x * 18 + k) * (x - 18)
               + (x * 19 + k) * (x - 19)
               + (x * 20 + k) * (x - 20)
               + (x * 21 + k) * (x - 21)     -- y dead, x strict
      in if n > 100 then f else \x y -> f (x + 1) y
{-# NOINLINE run #-}

run :: Int -> Int -> [Int] -> Int
run n m xs = let h1 = g n; h2 = g m in sum (map (\x -> h1 x 0 + h2 x 0) xs)

main :: IO ()
main = print (run 10 200 [1 .. 5])
