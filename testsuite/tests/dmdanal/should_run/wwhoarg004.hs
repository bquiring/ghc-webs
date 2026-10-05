-- No split when the function parameter escapes: g is also stored in a list
-- (it could be called with anything there).  The program must be unchanged.
module Main (main) where

h :: ((Int -> Int -> Int) -> Int) -> Int -> (Int, [(Int -> Int -> Int) -> Int])
h g n = let k = sum [1 .. n]
            f x y = (x * 1 + k) * (x - 1) + (x * 2 + k) * (x - 2) + (x * 3 + k) * (x - 3) + (x * 4 + k) * (x - 4) + (x * 5 + k) * (x - 5) + (x * 6 + k) * (x - 6) + (x * 7 + k) * (x - 7) + (x * 8 + k) * (x - 8) + (x * 9 + k) * (x - 9) + (x * 10 + k) * (x - 10) + (x * 11 + k) * (x - 11) + (x * 12 + k) * (x - 12) + (x * 13 + k) * (x - 13) + (x * 14 + k) * (x - 14) + (x * 15 + k) * (x - 15) + (x * 16 + k) * (x - 16) + (x * 17 + k) * (x - 17) + (x * 18 + k) * (x - 18) + (x * 19 + k) * (x - 19) + (x * 20 + k) * (x - 20) + (x * 21 + k) * (x - 21)       -- y dead
        in (g f + f 1 2, [g, g])

main :: IO ()
main = do
  let (r, gs) = h (\f -> f 3 4) 10
      (r2, _) = h (\f -> f 5 6 * 2) 20
  print (r, r2, sum [ g (\a b -> a + b) | g <- gs ])
