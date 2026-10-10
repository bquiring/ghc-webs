-- Note [Useless elimination]: every lambda of apply's parameter web returns
-- a pair, raised to an unboxed tuple; no call uses the second component, so
-- it is dropped and the lambdas no longer compute it.  The call is not
-- scrutinised directly (arity raising wraps it), so this also needs Note
-- [Scrutinised constructions].
module Main (main) where

apply :: (Int -> (Int, Int)) -> [Int] -> Int
apply f xs = sum [ case f x of (a, _) -> a | x <- xs ]
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply (\x -> (x + 1, x * 7)) [1..10], apply (\x -> (x * 2, x - 3)) [1..10])
