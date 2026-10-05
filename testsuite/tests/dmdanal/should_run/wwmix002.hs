-- Mix: the returned functions come from several branches: a lambda, a
-- let-bound function, and an error (a dead end); one argument is dead, one
-- strict, one lazy (undefined at a call whose branch ignores it).
module Main (main) where
import Control.Exception

g :: Int -> (Int -> Int -> Int -> Int)
g n = let k = sum [1 .. n]
          f a x y = (x * 1 + k) * (x - 1)
               + (x * 2 + k) * (x - 2)
               + (x * 3 + k) * (x - 3)
               + (x * 4 + k) * (x - 4)
               + (x * 5 + k) * (x - 5)
               + (x * 6 + k) * (x - 6)
               + (x * 7 + k) * (x - 7) + (if x > 0 then 0 else a)   -- y dead
      in case n `mod` 3 of
           0 -> f
           1 -> \a x y -> x * k + 1                                  -- a, y dead
           _ -> if n > 1000 then error "wwmix002: too big" else \a x y -> f a (x + 2) y
{-# NOINLINE run #-}

run :: Int -> [Int] -> Int
run n xs = let h = g n in sum (map (\x -> h undefined x 0) xs)

run2 :: Int -> Int -> Int
run2 n x = g n 0 x 0 + g (n + 1) 1 x 1
{-# NOINLINE run2 #-}

main :: IO ()
main = do
  print (run 9 [1 .. 4], run 10 [1 .. 4], run 11 [1 .. 4], run2 9 3)
  r <- try (evaluate (run 1001 [1]))
  print (either (\(ErrorCall _) -> True) (const False) r)
