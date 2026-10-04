-- Type classes (dictionary-passing arrows), polymorphism, local recursive
-- functions, join points and higher-rank arguments.
{-# LANGUAGE RankNTypes #-}
module Main (main) where

class Shape a where
  area  :: a -> Double
  scale :: Double -> a -> a

data Square = Square Double
data Circle = Circle Double

instance Shape Square where
  area (Square s) = s * s
  scale k (Square s) = Square (k * s)

instance Shape Circle where
  area (Circle r) = 3 * r * r
  scale k (Circle r) = Circle (k * r)

totalArea :: Shape a => [a] -> Double
totalArea = sum . map area
{-# NOINLINE totalArea #-}

-- A local recursive function, called at two types
twice :: (forall b. b -> [b]) -> (Int, Bool) -> ([Int], [Bool])
twice f (n, b) = (f n, f b)
{-# NOINLINE twice #-}

loop :: Int -> Int
loop n = go n 0
  where
    go 0 acc = acc
    go k acc = go (k - 1) (acc + k)
{-# NOINLINE loop #-}

pick :: Bool -> Int -> Int
pick b x = let j y = y * 10 in if b then j x else j (x + 1)
{-# NOINLINE pick #-}

main :: IO ()
main = do
  print (totalArea [Square 1, scale 2 (Square 1)])
  print (totalArea [Circle 1])
  print (twice (\x -> [x, x]) (3, True))
  print (loop 100)
  print (pick True 1, pick False 1)
