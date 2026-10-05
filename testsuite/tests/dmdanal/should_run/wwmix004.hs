-- Mix: an overloaded function that returns a function: a dictionary
-- argument, work before the returned function, and a dead argument; used at
-- two types.  (Large enough not to be inlined whole.)
module Main (main) where

g :: Num a => a -> (a -> a -> a)
g n = let k = sum (replicate 50 n)
          f x y = x * x + k * x + (x * 1 + k) * (x - 1) + (x * 2 + k) * (x - 2) + (x * 3 + k) * (x - 3) + (x * 4 + k) * (x - 4) + (x * 5 + k) * (x - 5) + (x * 6 + k) * (x - 6) + (x * 7 + k) * (x - 7) + (x * 8 + k) * (x - 8) + (x * 9 + k) * (x - 9) + (x * 10 + k) * (x - 10) + (x * 11 + k) * (x - 11) + (x * 12 + k) * (x - 12) + (x * 13 + k) * (x - 13) + (x * 14 + k) * (x - 14) + (x * 15 + k) * (x - 15) + (x * 16 + k) * (x - 16) + (x * 17 + k) * (x - 17) + (x * 18 + k) * (x - 18) + (x * 19 + k) * (x - 19) + (x * 20 + k) * (x - 20) + (x * 21 + k) * (x - 21) + (x * 22 + k) * (x - 22) + (x * 23 + k) * (x - 23) + (x * 24 + k) * (x - 24)    -- y dead
      in f

run :: (Num a) => a -> [a] -> a
run n xs = let h = g n in sum (map (\x -> h x 0) xs)
{-# NOINLINE run #-}

run2 :: Int -> Int -> Int
run2 n x = let h = g n in h x 0 * h (x + 1) 0
{-# NOINLINE run2 #-}

main :: IO ()
main = print (run (3 :: Int) [1 .. 5], run (0.5 :: Double) [1, 2], run2 4 5)
