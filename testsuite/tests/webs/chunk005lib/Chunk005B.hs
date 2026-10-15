module Chunk005B (sumWith, sizes) where
import {-# SOURCE #-} Chunk005A
sumWith :: (a -> Int) -> [a] -> Int
sumWith f = foldr (\x acc -> f x + acc) 0
sizes :: [T] -> Int
sizes = sumWith size
