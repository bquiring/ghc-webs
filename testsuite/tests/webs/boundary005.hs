-- Note [Contracting the boundary split]: step and keep are both exported and
-- split.  step's second argument is dead, so its local copy changes and the
-- split is kept; keep's copy is unchanged, so its split is undone.
module Main (main, step, keep) where

step :: Int -> Int -> Int
step x _ = x * 3 + 1

keep :: Int -> Int -> Int
keep x y = x * y + 1

apply2 :: (Int -> Int -> Int) -> Int -> Int
apply2 f n = f n n + f (n + 1) n
{-# NOINLINE apply2 #-}

twice :: (Int -> Int -> Int) -> Int -> Int
twice f n = f n (f n n)
{-# NOINLINE twice #-}

main :: IO ()
main = print (apply2 step 4, twice keep 3, step 5 6, keep 2 3)
