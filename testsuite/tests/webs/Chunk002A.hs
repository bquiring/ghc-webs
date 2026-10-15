module Chunk002A (Shape(..), area, mapShapes, Scale(..), helperA) where
-- exported constructors: outside modules match on them, so the merged
-- program must keep their representation
data Shape = Circle Double | Rect Double Double
  deriving Show
area :: Shape -> Double
area (Circle r) = 3 * r * r
area (Rect w h) = w * h
mapShapes :: (Shape -> Shape) -> [Shape] -> [Shape]
mapShapes f = map f
{-# NOINLINE mapShapes #-}
class Scale a where
  scale :: Double -> a -> a
instance Scale Shape where
  scale k (Circle r) = Circle (k * r)
  scale k (Rect w h) = Rect (k * w) (k * h)
-- used only inside the chunk (Chunk002B)
helperA :: (Int -> Int) -> Int -> Int
helperA g x = g (g x)
{-# NOINLINE helperA #-}
