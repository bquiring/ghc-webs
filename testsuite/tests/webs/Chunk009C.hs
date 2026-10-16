module Chunk009C (run) where

import Chunk009D (d)

run :: Int -> Int
run n = sum (map d [1 .. n])
