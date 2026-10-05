-- Constant results: every function of the web returns True (or fails), so
-- a case on a call picks the True alternative.
module Main (main) where

check :: (Int -> Bool) -> Int -> Int
check f n = case f n of
  True  -> n + 1
  False -> n - 1
{-# NOINLINE check #-}

big, positive :: Int -> Bool
big n = if n > 1000000 then error "constprop002: too big" else True
positive n = n `seq` True
{-# NOINLINE big #-}
{-# NOINLINE positive #-}

main :: IO ()
main = print (sum [ check big i + check positive i | i <- [1 .. 100] ])
