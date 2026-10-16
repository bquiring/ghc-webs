module Chunk010C (run) where

import Chunk010X (xValue, xCount)

run :: Int -> Int
run n = n * xValue + xCount []
