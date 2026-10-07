-- Webs that are not defunctionalised (Note [Defunctionalisation]):
--  * twiceP is polymorphic: its parameter's arrow is  a -> a;
--  * go is a let-bound function that is called directly (known calls) and
--    also passed to apply1.
module Main (main) where

twiceP :: (a -> a) -> a -> a
twiceP f x = f (f x)
{-# NOINLINE twiceP #-}

apply1 :: (Int -> Int) -> Int -> Int
apply1 f x = f x + 1
{-# NOINLINE apply1 #-}

count :: Int -> Int
count m = let go :: Int -> Int
              go i = if i > m then i else go (i * 2)
              {-# NOINLINE go #-}
          in go 1 + apply1 go 3
{-# NOINLINE count #-}

main :: IO ()
main = print (twiceP (\y -> y + 1) (1 :: Int), twiceP not True, count 10)
