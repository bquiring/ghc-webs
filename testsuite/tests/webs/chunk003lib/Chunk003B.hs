module Chunk003B (total, twiceAll) where
import Chunk003A
total :: [Shape] -> Double
total = sum . map area
twiceAll :: [Int] -> [Int]
twiceAll = map (helperA (+ 1))
