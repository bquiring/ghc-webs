-- -fcore-webs-boundary-kept (Note [Splitting kept binders] in
-- GHC.WebCore.Boundary): the specialiser's $sinsert (Data.Map.insert at Int
-- keys, INLINABLE) is mentioned by the rule for insert, so it keeps its
-- type and its webs were exposed.  With the flag it is split: only its
-- wrapper's lambdas stay exposed.
module Main (main) where

import qualified Data.Map as M

build :: Int -> M.Map Int Int
build n = foldr (\i m -> M.insert i (i * 2) m) M.empty [1 .. n]
{-# NOINLINE build #-}

main :: IO ()
main = do
  let m = build 10
  print (M.foldr (+) 0 m)
  print (M.lookup 3 m, M.size m)
