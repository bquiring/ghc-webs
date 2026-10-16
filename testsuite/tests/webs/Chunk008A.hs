module Chunk008A (base) where

import Chunk008B

-- The chunk's last module: the chunk {Chunk008A, Chunk008B} is merged into it
base :: Int
base = scale 2 [1, 2, 3]
