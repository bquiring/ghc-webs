-- Nested boxes: pairs of pairs, Maybe and Either inside lists; deep
-- unboxing, within the size bound or not.
module Main (main) where

deep :: Int -> [(Int, (Int, (Int, Int)))]
deep n = [ (i, (i + 1, (i + 2, i + 3))) | i <- [1 .. n] ]
{-# NOINLINE deep #-}

sumDeep :: [(Int, (Int, (Int, Int)))] -> Int
sumDeep []                        = 0
sumDeep ((a, (b, (c, d))) : r)    = a + b + c + d + sumDeep r
{-# NOINLINE sumDeep #-}

maybes :: Int -> [Maybe (Int, Int)]
maybes n = [ if even i then Just (i, i) else Nothing | i <- [1 .. n] ]
{-# NOINLINE maybes #-}

sumMaybes :: [Maybe (Int, Int)] -> Int
sumMaybes []                  = 0
sumMaybes (Nothing : r)       = sumMaybes r
sumMaybes (Just (a, b) : r)   = a * b + sumMaybes r
{-# NOINLINE sumMaybes #-}

eithers :: Int -> [Either (Int, Int) Int]
eithers n = [ if i `mod` 3 == 0 then Left (i, i) else Right i | i <- [1 .. n] ]
{-# NOINLINE eithers #-}

sumEithers :: [Either (Int, Int) Int] -> Int
sumEithers []                  = 0
sumEithers (Left (a, b) : r)   = a + b + sumEithers r
sumEithers (Right c : r)       = c + sumEithers r
{-# NOINLINE sumEithers #-}

main :: IO ()
main = do
  print (sumDeep (deep 100))
  print (sumMaybes (maybes 100))
  print (sumEithers (eithers 100))
