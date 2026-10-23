module RuleCopy001A (look) where

-- base's lookup; INLINABLE, so Specialise copies it at Int in Main
look :: Eq a => a -> [(a, b)] -> Maybe b
look _key [] = Nothing
look key ((x, y) : xys)
  | key == x  = Just y
  | otherwise = look key xys
{-# INLINABLE look #-}
