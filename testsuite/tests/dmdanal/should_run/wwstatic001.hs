-- (Static): recursive functions passing their function parameter on
-- unchanged.  See (Static) in Note [Worker/wrapper for function arguments].
module Main (main) where

import Debug.Trace (trace)

-- [+] g passed on at every level; f's y is dead.  k is traced: one "k" per
-- level, however many times g calls f.
hS :: ((Int -> Int -> Int) -> Int) -> Int -> Int
hS g n | n <= 0    = 0
       | otherwise = let k = trace "k" (n * 3)
                         f x y = (x + k) * (x - 1) + (x * 2 + k) * (x - 2) + (x * 3 + k) * (x - 3)
                     in g f + hS g (n - 1)

-- [+] g undefined and never called (n <= 0 at once), or only called at
-- the bottom of the recursion
hBottom :: ((Int -> Int -> Int) -> Int) -> Int -> Int
hBottom g n | n <= 0    = 1
            | n == 1    = let f x _ = x * n + 7 in g f
            | otherwise = hBottom g (n - 1) + n

-- [+] (C) with a static continuation: k is always called with a pair
loopK :: ((Int, Int) -> r) -> Int -> Int -> r
loopK k acc n | n == 0    = k (acc, n * 2)
              | otherwise = loopK k (acc + n) (n - 1)

-- [-] g and f swap positions: not static
sw :: (Int -> Int) -> (Int -> Int) -> Int -> Int
sw g f n | n <= 0    = g (f 1)
         | otherwise = sw f g (n - 1) + g n

-- [-] g and h swap positions, and g is given a local function: not static
-- (passing g at h's position would lose the alternation)
sw2 :: ((Int -> Int -> Int) -> Int) -> ((Int -> Int -> Int) -> Int) -> Int -> Int
sw2 g h n | n <= 0    = 0
          | otherwise = let f x y = (x + n) * (x - 1) + (x * 2 + n) * (x - 2) + (x * 3 + n) * (x - 3)
                        in g f + sw2 h g (n - 1)

-- [-] polymorphic recursion: the recursive call is at type [a], so it
-- cannot call the worker instantiated at a
data Nest a = Flat Int a | Nest (Nest [a])

pr :: ((Int -> Int -> Int) -> Int) -> Nest a -> Int
pr g (Flat k _) = let f x y = (x + k) * (x - 1) + (x * 2 + k) * (x - 2) + (x * 3 + k) * (x - 3)
                  in g f
pr g (Nest n) = 1 + pr g n

-- [+] a local recursive function with a static function parameter
outer :: ((Int -> Int -> Int) -> Int) -> Int -> Int
outer g0 m = go g0 m
  where
    go g n | n <= 0    = m
           | otherwise = let f x y = x * n + (x + 1) * (n - 1) + (x + 2) * (n - 2) + (x + 3) * (n - 3)
                         in g f + go g (n - 1)

main :: IO ()
main = do
  print (hS (\f -> f 2 0 + f 3 undefined) 3)
  print (hS undefined 0)
  print (hBottom undefined 0, hBottom (\f -> f 5 undefined) 4)
  print (hBottom (\f -> f 5 undefined) 1)
  print (loopK (\(a, b) -> a + b) 0 10, loopK fst 1 5)
  print (loopK (\p -> case p of (a, _) -> a) 0 (3 :: Int))
  print (loopK (const 'x') 0 4, loopK (\p -> snd p `seq` 'y') 0 2)
  print (sw (+ 1) (* 2) 5, sw (subtract 3) negate 4)
  print (sw2 (\f -> f 1 undefined) (\f -> f 2 undefined * 100) 5)
  print (pr (\f -> f 4 undefined) (Nest (Nest (Flat 3 [[True]]))))
  print (outer (\f -> f 1 undefined) 4, outer (const 0) 0)
  -- partial applications are values
  print (hS undefined `seq` (), loopK undefined 0 `seq` ())
