-- Laziness: a function flows into a local polymorphic function that forces
-- its argument.  The web appears in a type argument (myseq @(Int -> Int)),
-- so it must become a unit web.  This test fails if the parameter is deleted
-- (forcing 'k' would then diverge).
module Main (main) where

myseq :: a -> b -> b
myseq x y = x `seq` y
{-# NOINLINE myseq #-}

apply :: (Int -> Int) -> Int -> Int
apply f n = if n > 0 then f n else 0
{-# NOINLINE apply #-}

k :: Int -> Int
k _ = undefined
{-# NOINLINE k #-}

main :: IO ()
main = do
  print (myseq k ())
  print (apply k 0)
