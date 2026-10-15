-- Unused exports (Note [Unused exports] in GHC.WebCore.Pipeline): Unused001L's
-- unusedHO is listed in unused001.txt, so it is no longer exported and the
-- simplifier deletes it; the program still links and runs.
module Main (main) where
import Unused001L
main :: IO ()
main = print (twice (+1) 5 + helper 2)
