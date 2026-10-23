-- Note [Copying the binders of rules] in GHC.WebCore.Boundary: V's derived
-- Eq instance is used inside the program (nub compares with it), which
-- exposes V's classes.  With -fcore-webs-instance-copies the program uses
-- its own copy of the instance, and V is no longer exposed
module Main (main) where

import Data.List ( nub )

data V = V Int Bool deriving (Eq, Show)

vs :: Int -> [V]
vs n = [ V (i `mod` 7) (even i) | i <- [1 .. n] ]
{-# NOINLINE vs #-}

count :: [V] -> Int
count xs = length (nub xs)
{-# NOINLINE count #-}

main :: IO ()
main = print (count (vs 1000))
