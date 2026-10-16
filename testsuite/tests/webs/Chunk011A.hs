module Chunk011A (AT(..), atSize, total) where

import Chunk011B

data AT = AT Int

atSize :: AT -> Int
atSize (AT n) = n

total :: Int -> Int
total n = sizes [ AT i | i <- [1 .. n] ]
