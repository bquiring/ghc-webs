-- Note [Splitting webs at the boundary], part 1: step is exported, and also
-- passed to the local apply2.  Its second argument is dead.  Without the
-- split, step's web is exposed and keeps the argument; with it, the local
-- copy $estep drops it, and apply2 no longer passes it.  (step is too big
-- to nearly inline; small functions are not split: boundary004.)
module Main (main, step) where

step :: Int -> Int -> Int
step x _
  | x > 1000  = x `div` 7 + x `mod` 13 + x `quot` 11 + x `rem` 17 + 2
  | x > 100   = x `div` 9 + x `mod` 19 + x `quot` 23 + x `rem` 29 + 3
  | x > 50    = x `div` 3 + x `mod` 31 + x `quot` 37 + x `rem` 41 + 4
  | even x    = x * 3 + x `div` 2 + 1
  | otherwise = x * 5 - x `mod` 3 + 1

apply2 :: (Int -> Int -> Int) -> Int -> Int
apply2 f n = f n n + f (n + 1) n
{-# NOINLINE apply2 #-}

main :: IO ()
main = print (apply2 step 4, step 5 6)
