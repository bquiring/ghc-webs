module Chunk010X (xValue, xLater) where

import {-# SOURCE #-} Chunk010M

xValue :: Int
xValue = 41

-- through the hs-boot file: Chunk010M itself is built after Chunk010X
xLater :: () -> Int
xLater () = mValue
