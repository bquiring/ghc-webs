{-# LANGUAGE BangPatterns #-}
module Main (main) where

-- Note [Evaluated arguments] in GHC.WebCore.Transform.ArityRaise: every call
-- passes a box the caller already has (a list element it has evaluated: a
-- case binder), and one lambda keeps the box (in a list): with
-- -fcore-webs-evald-args that lambda rebuilds it, an allocation the
-- original does not make.

keep :: (Double -> [Double]) -> [Double] -> [Double]
keep f = go
  where
    go []        = []
    go (!x : xs) = f x ++ go xs
{-# NOINLINE keep #-}

main :: IO ()
main = do
  let xs = [ fromIntegral i | i <- [1 .. 100000 :: Int] ]
  print (length (keep (\y -> [y, y]) xs))
  print (sum (keep (\y -> [y * 2]) xs))
