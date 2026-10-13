-- Lists are not "used as kinds" (Note [Types used as kinds] in
-- GHC.WebCore.DataSplit): getArgs's IO returns (# State# RealWorld,
-- [String] #), an unboxed tuple whose hidden representation arguments
-- mention the promoted '[] (State#'s representation is TupleRep '[]).
-- That excluded lists from splitting in every program with IO (nofib
-- queens, integer, cryptarithm2).  The local list here must still be split.
module Main (main) where

import System.Environment ( getArgs )

squares :: Int -> [Int]
squares n = [ i * i | i <- [1 .. n] ]
{-# NOINLINE squares #-}

total :: [Int] -> Int
total = go 0
  where go acc []       = acc
        go acc (y : ys) = go (acc + y) ys
{-# NOINLINE total #-}

main :: IO ()
main = do
  args <- getArgs
  print (total (squares (10 + length args)))
