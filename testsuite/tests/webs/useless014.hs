-- Note [Useless elimination]: a dead result component returned through a
-- join point (the lambda's tails jump to j, which builds the tuple).  The
-- dead component is an error in one branch: it must never be raised.
{-# LANGUAGE UnboxedTuples #-}
module Main (main) where

apply :: (Int -> (# Int, Int #)) -> [Int] -> Int
apply f xs = sum [ case f x of (# a, _ #) -> a | x <- xs ]
{-# NOINLINE apply #-}

step :: Int -> (# Int, Int #)
step x =
  let j :: Int -> (# Int, Int #)
      j k = (# k + 1, if k > 5 then errorWithoutStackTrace "useless014: component" else k #)
      {-# NOINLINE j #-}
  in if even x then j (x * 2) else j (x + 3)

main :: IO ()
main = print (apply step [1..10], apply (\x -> (# x, x #)) [1..3])
