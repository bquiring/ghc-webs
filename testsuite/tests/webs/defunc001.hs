-- Note [Defunctionalisation] (GHC.WebCore.Transform.Defunc): twice calls
-- its parameter, an unknown call, and two lambdas reach it, one capturing
-- k.  The web becomes a data type with two constructors, and twice's calls
-- become calls of the apply function, which GHC inlines: twice ends up
-- casing on its argument, with no unknown call left.
module Main (main) where

twice :: (Int -> Int) -> Int -> Int
twice f x = f (f x)
{-# NOINLINE twice #-}

k :: Int
k = length (show (12345 :: Int))
{-# NOINLINE k #-}

main :: IO ()
main = print (twice (\y -> y + k) 10, twice (\y -> y * 2) 5)
