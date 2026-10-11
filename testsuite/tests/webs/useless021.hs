-- Note [Useless elimination]: a join point bound in the tail of a lambda
-- whose second result component is dead, and with a dead parameter of its
-- own: its type loses the parameter's arrow, and the masked result must be
-- put after the arrows that remain (from network's IO code: panic
-- "Useless.replaceResult").
{-# LANGUAGE UnboxedTuples #-}
module Main (main) where

apply :: (Int -> (# Int, Int #)) -> [Int] -> Int
apply f xs = sum [ case f x of (# a, _ #) -> a | x <- xs ]
{-# NOINLINE apply #-}

step :: Int -> (# Int, Int #)
step x =
  let j :: Int -> Int -> (# Int, Int #)
      j k _ = (# k + 1, k * 2 #)
      {-# NOINLINE j #-}
  in if even x then j (x * 2) (x + 7) else j (x + 3) (x - 7)

main :: IO ()
main = print (apply step [1 .. 10], apply (\x -> (# x, x #)) [1 .. 3])
