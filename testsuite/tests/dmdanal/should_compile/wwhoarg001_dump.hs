-- WORKING-THE-WORKER-WRAPPER.md, the function-argument case (§2.2 of
-- WW-HIGHER-ORDER.md, not implemented yet): h passes its local function f,
-- whose second argument is dead, to its function argument g.  Today g
-- receives f's wrapper, and every call of f by g passes the dead argument.
-- Approach 2 would pass f's worker to g, with a wrapper for h adapting the
-- caller's g (three layers: h, g's argument, f).
module WWHoArg_001 (main, h) where

h :: ((Int -> Int -> Int) -> Int) -> Int -> Int
h g n = let k = sum [1 .. n]
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
               + (x * 21 + k) * (x - 21)       -- y dead
        in f 1 2 + f 3 4 + g f

main :: IO ()
main = print (h (\f -> f 1 2 * f 2 3) 5, h (\f -> f 5 6 + f 7 8) 10, h (\f -> sum (map (\x -> f x x) [1 .. 4])) 20)
