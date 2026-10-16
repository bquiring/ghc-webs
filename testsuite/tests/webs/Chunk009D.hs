module Chunk009D (f, d) where

-- Re-exports f, which nothing outside the chunk {Chunk009D, Chunk009E}
-- uses: the chunk's unused-exports list cuts it from Chunk009E
import Chunk009E

d :: Int -> Int
d x = g (f x)
