-- Note [Splitting webs at the boundary], part 1: step is exported, and small
-- enough to certainly inline, so it is not split (unlike boundary001): its
-- web stays exposed and keeps the dead argument, and other modules inline
-- its whole body instead.
module Main (main, step) where

step :: Int -> Int -> Int
step x _ = x * 3 + 1

apply2 :: (Int -> Int -> Int) -> Int -> Int
apply2 f n = f n n + f (n + 1) n
{-# NOINLINE apply2 #-}

main :: IO ()
main = print (apply2 step 4, step 5 6)
