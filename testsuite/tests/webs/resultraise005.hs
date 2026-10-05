-- The case binder of a scrutinised call is used, so the re-boxed pair must
-- be rebuilt from the components; the caller returns it.
module Main (main) where

pick :: (Int -> (Int, Int)) -> Int -> (Int, Int)
pick f n = case f n of p@(a, _) -> if a > 10 then p else (0, a)
{-# NOINLINE pick #-}

p1, p2 :: Int -> (Int, Int)
p1 n = (n * 2, n)
p2 n = (n + 100, n - 1)
{-# NOINLINE p1 #-}
{-# NOINLINE p2 #-}

main :: IO ()
main = print (pick p1 3, pick p1 30, pick p2 1)
