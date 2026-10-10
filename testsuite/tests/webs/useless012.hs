-- Note [Useless elimination]: mutual recursion.  f and g only pass y to
-- each other; the fixpoint finds it dead in both.  The initial argument is
-- an error: it must never be evaluated.
module Main (main) where

f, g :: Int -> Int -> Int
f x y = if x == 0 then 1 else 1 + g (x - 1) y
g x y = if x == 0 then 0 else 3 * f (x - 1) y
{-# NOINLINE f #-}
{-# NOINLINE g #-}

apply :: (Int -> Int -> Int) -> Int -> Int
apply h n = h n (errorWithoutStackTrace "useless012: y forced")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply f 10, apply g 11)
