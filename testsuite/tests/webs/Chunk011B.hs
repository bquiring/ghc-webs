module Chunk011B (sizes) where

import {-# SOURCE #-} Chunk011A

sizes :: [AT] -> Int
sizes = sum . map atSize
