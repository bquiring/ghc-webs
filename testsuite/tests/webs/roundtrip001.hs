-- Note [Occurrences after the round trip] in GHC.WebCore.Erase: with the
-- web pass on and nothing transformed, the final Core must be the same as
-- without it.  Occurrences carrying their binders' IdInfo after erasure made
-- tak's worker keep its arguments boxed (the SML benchmark cpstak, +17%).
module Main (main) where

cpstak :: Int -> Int -> Int -> Int
cpstak x0 y0 z0 = tak x0 y0 z0 (\a -> a)
  where
    tak :: Int -> Int -> Int -> (Int -> Int) -> Int
    tak x y z k
      | y >= x    = k z
      | otherwise = tak (x - 1) y z (\v1 ->
                      tak (y - 1) z x (\v2 ->
                        tak (z - 1) x y (\v3 ->
                          tak v1 v2 v3 k)))
{-# NOINLINE cpstak #-}

main :: IO ()
main = print (cpstak 14 11 0)
