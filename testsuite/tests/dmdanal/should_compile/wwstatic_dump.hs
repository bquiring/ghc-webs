-- (Static) in Note [Worker/wrapper for function arguments]: recursive
-- functions passing their function parameter on unchanged.  Split: hS
-- (its worker calls itself with the converted g) and loopK ((C), a static
-- continuation).  Not split: sw2 (g and h swap positions) and pr
-- (polymorphic recursion).
module WWStaticDump (hS, loopK, sw2, pr, Nest(..)) where

hS :: ((Int -> Int -> Int) -> Int) -> Int -> Int
hS g n | n <= 0    = 0
       | otherwise = let k = n * 3
                         f x y = (x + k) * (x - 1) + (x * 2 + k) * (x - 2) + (x * 3 + k) * (x - 3)
                     in g f + hS g (n - 1)

loopK :: ((Int, Int) -> r) -> Int -> Int -> r
loopK k acc n | n == 0    = k (acc, n * 2)
              | otherwise = loopK k (acc + n) (n - 1)

sw2 :: ((Int -> Int -> Int) -> Int) -> ((Int -> Int -> Int) -> Int) -> Int -> Int
sw2 g h n | n <= 0    = 0
          | otherwise = let f x y = (x + n) * (x - 1) + (x * 2 + n) * (x - 2) + (x * 3 + n) * (x - 3)
                        in g f + sw2 h g (n - 1)

data Nest a = Flat Int a | Nest (Nest [a])

pr :: ((Int -> Int -> Int) -> Int) -> Nest a -> Int
pr g (Flat k _) = let f x y = (x + k) * (x - 1) + (x * 2 + k) * (x - 2) + (x * 3 + k) * (x - 3)
                  in g f
pr g (Nest n) = 1 + pr g n
