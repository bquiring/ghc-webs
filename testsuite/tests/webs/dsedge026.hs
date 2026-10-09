-- Recursive types holding functions (call demands inside product demands),
-- for the transformations that change functions: arity raising, result
-- raising, defunctionalisation.  A Mealy machine returns an output pair and
-- its next state; a continuation type is recursive through a function's
-- result; a stream of functions never ends.
module Main (main) where

data Mealy = Mealy (Int -> ((Int, Int), Mealy))

counter :: Int -> Mealy
counter s = Mealy (\x -> ((s, s * x), counter (s + x)))
{-# NOINLINE counter #-}

run :: Int -> Mealy -> (Int, Int)
run 0 _         = (0, 0)
run k (Mealy f) = case f k of
  ((a, b), m) -> case run (k - 1) m of (c, d) -> (a + c, b + d)
{-# NOINLINE run #-}

data K = More Int (Int -> K) | Done (Int, Int)

collatz :: Int -> Int -> K
collatz n c
  | n == 1    = Done (n, c)
  | otherwise = More n (\m -> collatz (if even m then m `div` 2 else 3 * m + 1) (c + 1))
{-# NOINLINE collatz #-}

drive :: K -> (Int, Int)
drive (Done p)   = p
drive (More n k) = drive (k n)
{-# NOINLINE drive #-}

data FS = FS (Int -> Int) FS

fns :: Int -> FS
fns k = FS (\x -> x * k + 1) (fns (k + 1))
{-# NOINLINE fns #-}

applyN :: Int -> Int -> FS -> Int
applyN 0 x _        = x
applyN n x (FS f r) = applyN (n - 1) (f x `mod` 100003) r
{-# NOINLINE applyN #-}

main :: IO ()
main = do
  print (run 50 (counter 1))
  print (map (\n -> drive (collatz n 0)) [6, 7, 27])
  print (applyN 40 1 (fns 2))
