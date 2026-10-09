-- Note [Uncurrying known calls]: apply2's parameter is called with two
-- arguments at an unknown call, so its web is uncurried; addK's web has only
-- known calls, which GHC already makes direct, so it is left alone.
module Main (main) where

apply2 :: (Int -> Int -> Int) -> Int -> Int
apply2 f n = f n (n + 1) + f (n + 2) n
{-# NOINLINE apply2 #-}

addK :: Int -> Int -> Int
addK a b = a * b + 1
{-# NOINLINE addK #-}

main :: IO ()
main = do
  k <- return (length "abc")     -- the lambdas have a free variable, so they stay lambdas
  print (apply2 (\a b -> a * k - b) 10 + apply2 (\a b -> a * b + k) 3)
  print (addK 4 5 + addK 6 7)
