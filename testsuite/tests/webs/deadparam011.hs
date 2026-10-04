-- A dead web used polymorphically: 'poly' is called at two types.  Deleting
-- the parameter gives poly :: forall a. Int -> a -> Int, which is still
-- well-typed at both calls.
module Main (main) where

poly :: (a -> Int) -> a -> Int
poly g x = g x + 1
{-# NOINLINE poly #-}

c :: Bool -> Int
c _ = 5
{-# NOINLINE c #-}

d :: Char -> Int
d _ = 6
{-# NOINLINE d #-}

main :: IO ()
main = print (poly c True + poly d 'x')
