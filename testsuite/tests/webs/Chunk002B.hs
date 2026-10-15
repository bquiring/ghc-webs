module Chunk002B (total, twiceAll) where
import Chunk002A
total :: [Shape] -> Double
total = sum . map area
twiceAll :: [Int] -> [Int]
twiceAll = map (helperA (+ 1))
