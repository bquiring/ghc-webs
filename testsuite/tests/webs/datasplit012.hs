-- A split copy that drops a constructor renumbers the rest, but tags the
-- simplifier folded into literals keep the original numbering (Note
-- [Observed tags] in GHC.WebCore.DataSplit).  V's derived (==), an
-- unfolding from another module, compares tags: in newDeps, F k == v
-- becomes case lvl of I# t -> case t of 1# -> case v of F y -> ..., with
-- dataToTag# v floated out of the loop and 1# F's original tag.  Values
-- from pick are only F or S, so their copy drops P; with F and S
-- renumbered, an S took the F branch and failed its pattern match
-- (cabal-install's solver, Distribution.Solver.Modular.Linking).
module Main (main) where

import Datasplit012V

pick :: Int -> V Int
pick n = if even n then F n else S n
{-# NOINLINE pick #-}

-- As in the solver's linkNewDeps: the comparison is in a local recursive
-- function, out of which full laziness floats dataToTag# v, boxed
data Dep = Flagged Int [Dep] [Dep] | Stanza Int [Dep] | Simple Int

newDeps :: V Int -> Bool -> [Dep] -> [Int]
newDeps v b = concatMap go
  where
    go (Simple k)        = [k]
    go (Flagged k t f)   = if F k == v then (if b then newDeps v b t else newDeps v b f) else []
    go (Stanza k t)      = if S k == v then (if b then newDeps v b t else []) else []
{-# NOINLINE newDeps #-}

deps :: Int -> [Dep]
deps n = [ Flagged k [Simple (10 * k)] [Simple (100 * k)] | k <- [1 .. n] ]
         ++ [ Stanza k [Simple (1000 * k)] | k <- [1 .. n] ]
{-# NOINLINE deps #-}

main :: IO ()
main = do
  print [ newDeps (pick n) True (deps 4) | n <- [1 .. 4] ]
  print [ newDeps (pick n) False (deps 4) | n <- [1 .. 4] ]
