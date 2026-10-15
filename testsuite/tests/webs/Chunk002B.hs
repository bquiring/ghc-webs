module Chunk002B (total, twiceAll, label) where
import Chunk002A (Shape, area, helperA)
total :: [Shape] -> Double
total = sum . map area
twiceAll :: [Int] -> [Int]
twiceAll = map (helperA (+ 1))
-- exported, used by no module outside the chunk (chunk002.unused): the
-- merged program's own list must not unexport Chunk002A's field label
label :: Int -> String
label = show
{-# NOINLINE label #-}
