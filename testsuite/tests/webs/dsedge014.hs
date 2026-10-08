-- Values escaping to code compiled without the analysis: shown, stored in
-- an IORef, passed to map and uncurry, and returned whole.
module Main (main) where

import Data.IORef

mk :: Int -> [(Int, Int)]
mk n = [ (i, i * 10) | i <- [1 .. n] ]
{-# NOINLINE mk #-}

pick :: [(Int, Int)] -> (Int, Int)
pick ps = ps !! 2
{-# NOINLINE pick #-}

main :: IO ()
main = do
  let ps = mk 5
  print ps
  ref <- newIORef (head ps)
  modifyIORef ref (\(a, b) -> (b, a))
  readIORef ref >>= print
  print (map (uncurry (+)) ps)
  print (pick ps)
