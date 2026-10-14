-- A split type specialised to an instance whose variables occur only inside
-- a function type, with a coercion through it: specialiseSplit rebuilt the
-- coercion by selecting each variable out of the argument coercions along
-- its path in the pattern, and a variable under an arrow has no such path
-- (panic "specialiseSplit: pattern variable not in pattern", building
-- vector-algorithms' Data.Vector.Algorithms.Tim).  Such a type is no longer
-- specialised (Note [Specialising split types] in GHC.WebCore.DataSpec).
module Main (main) where

import Data.Coerce ( coerce )

newtype Age = Age Int

mk :: Int -> (Int -> Age, Int)
mk n = (\x -> Age (x + n), n * 2)
{-# NOINLINE mk #-}

use :: (Int -> Int, Int) -> Int
use (h, m) = h m + m
{-# NOINLINE use #-}

main :: IO ()
main = print (sum [ use (coerce (mk i)) | i <- [1 .. 10] ])
