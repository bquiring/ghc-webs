-- Re-boxing: pairs taken out of one list and stored into another, compared
-- with (==) (a class method), and kept in a list that is shown.
module Main (main) where

src :: Int -> [(Int, Int)]
src n = [ (i, i * i) | i <- [1 .. n] ]
{-# NOINLINE src #-}

swapAll :: [(Int, Int)] -> [(Int, Int)]
swapAll []           = []
swapAll ((a, b) : r) = (b, a) : swapAll r
{-# NOINLINE swapAll #-}

keep :: [(Int, Int)] -> [(Int, Int)]
keep []       = []
keep (p : r)  = if fst p > 3 then p : keep r else keep r
{-# NOINLINE keep #-}

total :: [(Int, Int)] -> Int
total []           = 0
total ((a, b) : r) = a - b + total r
{-# NOINLINE total #-}

main :: IO ()
main = do
  let ps = src 6
  print (total (swapAll ps))
  print (keep ps)
  print (length (filter (== (2, 4)) ps))
