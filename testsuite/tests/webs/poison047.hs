-- Dead constructors (Note [Data splitting again] in GHC.WebCore.Pipeline):
-- Square is built only as the argument of a dead parameter; once useless
-- elimination deletes that argument, Square is never built, and splitting
-- again drops it and area's Square alternative.  The dead argument is
-- poison.  (Deadness and strictness: the program must behave as it does
-- unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

data Shape = Circle Int | Square Int

area :: Shape -> Int
area (Circle r) = r * r * 3
area (Square s) = s * s
{-# NOINLINE area #-}

apply :: (Int -> Shape -> Int) -> Int -> Int
apply h n = h n (Square (poison "square side"))
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply (\a _ -> a * 2) 5, apply (\a _ -> a + 1) 6, map (area . Circle) [1, 2, 3])
