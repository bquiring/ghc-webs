-- Note [Early dead parameters] in GHC.WebCore.Transform.DeadParams, via
-- useless elimination: the last parameter of the web is dead.  Deleting it
-- would turn each lambda into a thunk, and the traced work, done once per
-- call, would be shared: the trace must appear once per call (3 times;
-- the arguments differ, so that CSE cannot merge the calls).
module Main (main) where

import Debug.Trace

apply :: (Int -> Int -> Int) -> Int -> Int
apply h n = h n 0 + h (n + 1) 1 + h (n + 2) 2
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply (\a _ -> trace "useless009: work" (a * 10)) 4)
