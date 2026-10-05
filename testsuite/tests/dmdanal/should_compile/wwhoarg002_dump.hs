-- Deeper function-argument nesting (§2.2, not implemented yet): f, with a
-- dead argument, is passed to a function that is itself passed to the
-- argument k, and f is called inside that.  A split would need wrappers
-- for h, k's argument, that argument's argument, and f.
module WWHoArg_002 (main, h) where

h :: ((((Int -> Int -> Int) -> Int) -> Int) -> Int) -> Int -> Int
h k n = let c = sum [1 .. n]
            f x y = (x * 1 + c) * (x - 1)
               + (x * 2 + c) * (x - 2)
               + (x * 3 + c) * (x - 3)
               + (x * 4 + c) * (x - 4)
               + (x * 5 + c) * (x - 5)
               + (x * 6 + c) * (x - 6)
               + (x * 7 + c) * (x - 7)
               + (x * 8 + c) * (x - 8)
               + (x * 9 + c) * (x - 9)
               + (x * 10 + c) * (x - 10)
               + (x * 11 + c) * (x - 11)
               + (x * 12 + c) * (x - 12)
               + (x * 13 + c) * (x - 13)
               + (x * 14 + c) * (x - 14)
               + (x * 15 + c) * (x - 15)
               + (x * 16 + c) * (x - 16)
               + (x * 17 + c) * (x - 17)
               + (x * 18 + c) * (x - 18)
               + (x * 19 + c) * (x - 19)
               + (x * 20 + c) * (x - 20)
               + (x * 21 + c) * (x - 21)       -- y dead
        in f 1 2 + f 3 4 + k (\g -> g f + g f)

main :: IO ()
main = print (h (\use -> use (\f -> f 9 9)) 7, h (\use -> use (\f -> f 5 6)) 10, h (\use -> use (\f -> f 1 1) * 2) 3)
