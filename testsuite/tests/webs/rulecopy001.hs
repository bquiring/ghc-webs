-- Note [Copying the binders of rules] in GHC.WebCore.Boundary: Specialise
-- copies look at Int ($slook) and writes a rule that mentions the copy,
-- which exposes its webs.  With -fcore-webs-rule-copies the program calls
-- its own copy of $slook, whose key the early run raises (Note [Lazy
-- parameters of known functions] in GHC.WebCore.Transform.ArityRaise)
module Main (main) where

import RuleCopy001A

main :: IO ()
main = do
  let table = [ (i, i * 3) | i <- [1 .. 200 :: Int] ]
  print (sum [ maybe 0 id (look k table) | k <- [1 .. 300 :: Int] ])
