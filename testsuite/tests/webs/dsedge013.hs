-- seq, foldl' and length on structures whose fields hold errors: only
-- what is forced may fail.
module Main (main) where

import Control.Exception
import Data.List (foldl')

pairs :: Int -> [(Int, Int)]
pairs n = [ (i, if i == 5 then error "five" else i) | i <- [1 .. n] ]
{-# NOINLINE pairs #-}

main :: IO ()
main = do
  let ps = pairs 10
  print (length ps)
  print (ps `seq` "spine forced")
  print (foldl' (\acc (a, _) -> acc + a) 0 ps)
  r <- try (evaluate (foldl' (\acc (_, b) -> acc + b) 0 ps))
  putStrLn (either (\(ErrorCall m) -> "caught: " ++ m) show r)
  print (fst (head ps) `seq` snd (head ps))
