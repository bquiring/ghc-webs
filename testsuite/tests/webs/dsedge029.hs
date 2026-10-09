-- Strict recursive fields: a list with a strict pair and a strict tail (its
-- spine is built eagerly), a record with a strict count and lazy pair and
-- history, and seq on cells whose lazy fields are bottom, or whose strict
-- field is.
module Main (main) where

import Control.Exception

data SL = SN | SC !(Int, Int) !SL

fromTo :: Int -> Int -> SL
fromTo a b
  | a > b     = SN
  | otherwise = SC (a, b - a) (fromTo (a + 1) b)
{-# NOINLINE fromTo #-}

sumSL :: SL -> (Int, Int)
sumSL SN            = (0, 0)
sumSL (SC (a, b) r) = case sumSL r of (x, y) -> (x + a, y + b)
{-# NOINLINE sumSL #-}

data H = H !Int (Int, Int) H

hist :: Int -> H
hist n = H n (n, error "never") (hist (n + 1))
{-# NOINLINE hist #-}

counts :: Int -> H -> Int
counts 0 (H c _ _) = c
counts k (H c _ h) = c + counts (k - 1) h
{-# NOINLINE counts #-}

firstOf :: H -> Int
firstOf (H _ (a, _) _) = a
{-# NOINLINE firstOf #-}

main :: IO ()
main = do
  print (sumSL (fromTo 1 50))
  print (counts 30 (hist 5), firstOf (hist 9))
  H 1 (error "lazy pair") (error "lazy history") `seq` putStrLn "lazy fields not forced"
  r <- try (evaluate (SC (1, 2) (SC (error "strict pair") SN)))
  putStrLn (either (\(ErrorCall m) -> "caught: " ++ m) (const "no error") r)
