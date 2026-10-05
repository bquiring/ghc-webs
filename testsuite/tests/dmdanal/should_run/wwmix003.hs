-- Mix: a recursive function returning a function: one tail calls the
-- function itself; together with CPR (the returned function returns a
-- pair, which the caller takes apart) and an absent argument.
module Main (main) where

g :: Int -> (Int -> Int -> (Int, Int))
g n | n <= 0    = \x _ -> (x, x + 1)
    | otherwise = let k = sum [1 .. n]
                      r = g (n - 1)
                  in \x y -> case r x y of (a, b) -> ((a * 1 + k) * (a - 1) + (a * 2 + k) * (a - 2) + (a * 3 + k) * (a - 3) + (a * 4 + k) * (a - 4) + (a * 5 + k) * (a - 5), b + k)   -- y dead
{-# NOINLINE run #-}

run :: Int -> [Int] -> Int
run n xs = let h = g n in sum [ a + b | x <- xs, let (a, b) = h x 0 ]

main :: IO ()
main = print (run 3 [1 .. 4], run 0 [5])
