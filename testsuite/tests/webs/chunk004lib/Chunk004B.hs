module Chunk004B (sumT) where

import Chunk004A

sumT :: [T] -> Int
sumT ts = total [ a + b | T a b <- ts ]
