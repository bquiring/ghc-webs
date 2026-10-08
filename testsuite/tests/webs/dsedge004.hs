-- Coercions: newtype deriving (class methods reach the newtype through
-- coercions of dictionaries), and Semigroup/Monoid on a newtype over a list.
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Main (main) where

newtype Score = Score Int deriving (Eq, Ord, Show, Num)
newtype Bag = Bag [(Score, Score)] deriving (Semigroup, Monoid, Show)

bag :: Int -> Bag
bag n = Bag [ (Score i, Score (i * 3)) | i <- [1 .. n] ]
{-# NOINLINE bag #-}

weigh :: Bag -> Score
weigh (Bag ps) = go ps
  where go []           = 0
        go ((a, b) : r) = a + b + go r
{-# NOINLINE weigh #-}

main :: IO ()
main = do
  print (weigh (bag 10 <> bag 5))
  print (weigh mempty)
  print (bag 2)
  print (maximum [ s | (s, _) <- let Bag ps = bag 7 in ps ])
