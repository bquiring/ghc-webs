-- Exceptions in fields: a field that is eventually forced may raise its
-- exception earlier, but only if it is forced at all; any of the program's
-- exceptions may be the one raised (imprecise exceptions).
module Main (main) where

import Control.Exception

boom :: Int -> [(Int, Int)]
boom n = [ (i, if i == n then throw Overflow else i) | i <- [1 .. n] ]
{-# NOINLINE boom #-}

sumSnd :: [(Int, Int)] -> Int
sumSnd []           = 0
sumSnd ((_, b) : r) = b + sumSnd r
{-# NOINLINE sumSnd #-}

sumFst :: [(Int, Int)] -> Int
sumFst []           = 0
sumFst ((a, _) : r) = a + sumFst r
{-# NOINLINE sumFst #-}

main :: IO ()
main = do
  print (sumFst (boom 10))
  r <- try (evaluate (sumSnd (boom 10)))
  putStrLn (either (\e -> "caught: " ++ show (e :: ArithException)) show r)
