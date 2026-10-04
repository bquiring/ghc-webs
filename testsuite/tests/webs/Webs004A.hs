-- The "external" module for webs004: higher-order functions and data
-- structures of functions, used from another module.
module Webs004A
  ( Ops(..), applyOp, applyAll, mkOps, twice
  ) where

data Ops = Ops { opName :: String, opFun :: Int -> Int }

applyOp :: Ops -> Int -> Int
applyOp ops x = opFun ops x
{-# NOINLINE applyOp #-}

applyAll :: [Int -> Int] -> Int -> Int
applyAll fs x = foldr (\f acc -> f acc) x fs
{-# NOINLINE applyAll #-}

mkOps :: String -> (Int -> Int) -> Ops
mkOps = Ops
{-# NOINLINE mkOps #-}

twice :: (Int -> Int) -> Int -> Int
twice f x = f (f x)
{-# NOINLINE twice #-}
