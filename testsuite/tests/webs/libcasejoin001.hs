module Main (main) where

-- Note [Liberate case through join points] in GHC.Core.Opt.LiberateCase:
-- the predicate is defunctionalised; its case lies under a join point
-- that makes the recursive call, and liberate case unrolls the loop
-- through it: one loop per constructor (the joinrecs counted in the
-- final Core)

import Data.Char (isSpace, isDigit)

-- takeWhile1P-like: at least one character, a predicate the loop passes
-- unchanged; called with two different predicates
takeWhile1 :: (Char -> Bool) -> String -> Maybe (Int, String)
takeWhile1 p s = case s of
  (c : cs) | p c -> Just (go 1 cs)
  _              -> Nothing
  where
    go !n (c : cs) | p c = go (n + 1) cs
    go n cs              = (n, cs)
{-# NOINLINE takeWhile1 #-}

spaces, digits :: String -> Maybe (Int, String)
spaces = takeWhile1 (\c -> c == ' ' || c == '\n')
digits = takeWhile1 (\c -> isDigit c || c == '_')

count :: String -> Int
count s = case spaces s of
  Just (n, r) -> n + count r
  Nothing -> case digits s of
    Just (n, r) -> n + count r
    Nothing -> case s of
      (_ : r) -> count r
      [] -> 0

main :: IO ()
main = do
  let input = concat (replicate 2000 "   123_45   abc  9  ")
  print (count input)
