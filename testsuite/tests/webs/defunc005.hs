-- A web with a polymorphic lambda and a monomorphic one
-- (Note [Defunctionalisation]): id' :: forall a. a -> a and \y -> y + 1
-- both reach applyTo's call, at Int -> Int.  The data type is indexed by
-- the argument and result types, D a b; id''s constructor has the
-- existential a (id' = /\a. C2 @a ...), \y -> y + 1's fixes a ~ Int, b ~ Int.
module Main (main) where

applyTo :: (Int -> Int) -> Int -> Int
applyTo f x = f x * 10
{-# NOINLINE applyTo #-}

id' :: a -> a
id' x = x
{-# NOINLINE id' #-}

main :: IO ()
main = print (applyTo (\y -> y + 1) 3, applyTo id' 3, applyTo id' 4)
