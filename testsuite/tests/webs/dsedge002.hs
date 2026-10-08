-- Coercions: parameterised newtypes used at several types, so a split type
-- cannot be specialised to one instance; Wrap's axiom is eta-reducible.
module Main (main) where

newtype Wrap a = Wrap a
newtype Pairs a = Pairs [(a, a)]

mkPairs :: Num a => a -> Int -> Pairs a
mkPairs x n = Pairs [ (x * fromIntegral i, x) | i <- [1 .. n] ]
{-# NOINLINE mkPairs #-}

sumPairs :: Num a => Pairs a -> a
sumPairs (Pairs ps) = go ps
  where go []           = 0
        go ((a, b) : r) = a + b + go r
{-# NOINLINE sumPairs #-}

unwrapAll :: [Wrap (Int, Int)] -> Int
unwrapAll []                  = 0
unwrapAll (Wrap (a, b) : r)   = a * b + unwrapAll r
{-# NOINLINE unwrapAll #-}

main :: IO ()
main = do
  print (sumPairs (mkPairs (2 :: Int) 50))
  print (sumPairs (mkPairs (0.5 :: Double) 10))
  print (unwrapAll [ Wrap (i, i + 1) | i <- [1 .. 20] ])
