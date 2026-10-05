{-# OPTIONS_GHC -Wno-missing-methods #-}
module WWHoStats001 where

-- The statistics of -ddump-ww-ho-stats looped (counting through
-- [0 .. maxBound]) on a function whose function parameter is never called.
-- Here: the default methods of an Enum instance without fromEnum take a
-- function (via the dictionary), and fromEnum is a missing-method error.
data T = T Integer

instance Enum T where
  toEnum = T . fromIntegral

-- And directly: a function parameter that is never called
k :: (Int -> Int) -> Int -> Int
k f n = n * 2 + n `div` 3 + length (show n)
