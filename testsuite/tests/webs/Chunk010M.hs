module Chunk010M (MT(..), mValue) where

import Chunk010X

data MT = MT Int

mValue :: Int
mValue = xValue + 1
