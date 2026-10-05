-- Higher-order worker/wrapper (-fworker-wrapper-function-results): a shared
-- partial application  h = g n  captured by a lambda (so h is lazy).  The
-- wrapper binds the worker's result with a let, so after inlining it the
-- simplifier floats  wf = $wg n  out of h, and the lambda calls wf directly:
--     run n xs = let wf = ... $w$wg ... in map (\a -> wf a) xs
-- (See (LetOrCase) in Note [Worker/wrapper for function results].)
module WWFunRes005 (run, run2) where

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
               + (x * 21 + k) * (x - 21)
               + (x * 22 + k) * (x - 22)
               + (x * 23 + k) * (x - 23)
               + (x * 24 + k) * (x - 24)
               + (x * 25 + k) * (x - 25)
               + (x * 26 + k) * (x - 26)
               + (x * 27 + k) * (x - 27)
               + (x * 28 + k) * (x - 28)
               + (x * 29 + k) * (x - 29)   -- y dead
      in if n > 100 then f else \x y -> f (x + 1) y

-- h is captured by a lambda, and called once per element
run :: Int -> [Int] -> [Int]
run n xs = let h = g n in map (\a -> h a a) xs

run2 :: Int -> [Int] -> [Int]
run2 n xs = let h = g (n + 1) in map (\a -> h a 0) xs
