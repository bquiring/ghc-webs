-- Function arguments and function results together: h passes its local
-- function f (dead y) to g, and returns a function with a dead argument z.
module WWHoArg_006 (main, h) where

h :: ((Int -> Int -> Int) -> Int) -> Int -> (Int -> Int -> Int)
h g n = let k = sum [1 .. n]
            f x y = (x * 1 + k) * (x - 1) + (x * 2 + k) * (x - 2) + (x * 3 + k) * (x - 3) + (x * 4 + k) * (x - 4) + (x * 5 + k) * (x - 5) + (x * 6 + k) * (x - 6) + (x * 7 + k) * (x - 7) + (x * 8 + k) * (x - 8) + (x * 9 + k) * (x - 9) + (x * 10 + k) * (x - 10) + (x * 11 + k) * (x - 11) + (x * 12 + k) * (x - 12) + (x * 13 + k) * (x - 13) + (x * 14 + k) * (x - 14) + (x * 15 + k) * (x - 15) + (x * 16 + k) * (x - 16) + (x * 17 + k) * (x - 17) + (x * 18 + k) * (x - 18) + (x * 19 + k) * (x - 19) + (x * 20 + k) * (x - 20) + (x * 21 + k) * (x - 21)       -- y dead
            r = g f
        in \a z -> a * r + k             -- z dead

run :: Int -> [Int] -> Int
run n xs = let p = h (\f -> f n 0 + f 1 1) n in sum (map (\x -> p x 0) xs)

main :: IO ()
main = print (run 10 [1 .. 5], run 3 [2, 4], h (\f -> f 2 2) 4 5 6)
