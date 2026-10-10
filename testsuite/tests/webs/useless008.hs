-- Note [Scrutinised constructions]: a field read through the case binder
-- is live.  The pattern ignores the pair's second field, but the case
-- binder passes the whole pair on, so the field must keep its value.
module Main (main) where

apply :: (Int -> (Int, Int)) -> [Int] -> Int
apply f xs = sum [ case f x of p@(a, _) -> a + snd' p | x <- xs ]
{-# NOINLINE apply #-}

snd' :: (Int, Int) -> Int
snd' (_, b) = b
{-# NOINLINE snd' #-}

main :: IO ()
main = print (apply (\x -> (x + 1, x * 7)) [1..10], apply (\x -> (x * 2, x - 3)) [1..10])
