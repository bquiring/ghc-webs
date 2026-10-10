-- A join point returning a tuple whose second component is poison in one
-- branch and never read. (Deadness and strictness: the program must behave
-- as it does unoptimised.)
{-# LANGUAGE UnboxedTuples #-}
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

step :: Int -> (# Int, Int #)
step x =
  let j :: Int -> (# Int, Int #)
      j k = (# k + 1, if k > 4 then poison "join component" else k #)
      {-# NOINLINE j #-}
  in if even x then j (x * 2) else j (x + 3)

apply :: (Int -> (# Int, Int #)) -> [Int] -> Int
apply f xs = sum [ case f x of (# a, _ #) -> a | x <- xs ]
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply step [1 .. 10])
