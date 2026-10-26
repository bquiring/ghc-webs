module Roundtrip003A where

data Token = LBrace | SubRef (Int, String) | Unknown String
  deriving (Show, Eq, Ord)
data SubAssign = MkSubAssign (Int, String) [Token]
newtype Conditional = MkConditional [Token]

-- base's lookup and elem, which Specialise copies at Int (with exposed
-- boot-library unfoldings it copies base's own)
myLookup :: Eq a => a -> [(a, b)] -> Maybe b
myLookup _ [] = Nothing
myLookup k ((a, b) : r) = if k == a then Just b else myLookup k r
{-# INLINABLE myLookup #-}

myElem :: Eq a => a -> [a] -> Bool
myElem _ [] = False
myElem x (y : ys) = x == y || myElem x ys
{-# INLINABLE myElem #-}
