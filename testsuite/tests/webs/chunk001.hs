-- Chunks (Note [Chunks] in GHC.WebCore.Chunk): Main and Chunk001L compiled
-- as one Core program by ghc --make -fcore-webs-chunk.  Calls cross the
-- module boundary with functions; ($) and coerce need their compulsory
-- unfoldings inlined in the captured modules' own code (nofib
-- real/cacheprof panicked in runtimeRepPrimRep without).
module Main (main) where
import Chunk001L
import Data.Coerce (coerce)
newtype Age = Age Int
main :: IO ()
main = do
  print $ twice (+1) 5 + helper 2
  print $ sum (map (coerce :: Age -> Int) [Age 1, Age 2])
  print $ applyAll [(*2), subtract 1] 10
