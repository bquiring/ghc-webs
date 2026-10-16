module Chunk010X (xValue, xLater, xCount) where

import {-# SOURCE #-} Chunk010M

xValue :: Int
xValue = 41

-- through the hs-boot file: Chunk010M itself is built after Chunk010X
xLater :: () -> Int
xLater () = mValue

-- its type names Chunk010M's MT: the chunk's merge reads it from the
-- hs-boot interface (eps_is_boot, Note [Modules below a chunk])
xCount :: [MT] -> Int
xCount = length
{-# NOINLINE xCount #-}
