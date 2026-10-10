-- Note [Contracting the boundary split]: step is exported and small enough to
-- certainly inline.  It is split like any other exported function
-- (boundary001): its local copy drops the dead argument, so the split is
-- kept, and the wrapper and the copy are both small enough to inline.
module Main (main, step) where

step :: Int -> Int -> Int
step x _ = x * 3 + 1

apply2 :: (Int -> Int -> Int) -> Int -> Int
apply2 f n = f n n + f (n + 1) n
{-# NOINLINE apply2 #-}

main :: IO ()
main = print (apply2 step 4, step 5 6)
