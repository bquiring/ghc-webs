-- Note [Hidden fields] in GHC.WebCore.Sigs: local types, so the webs inside
-- their fields are internal.  H's function field takes a pair, which arity
-- raising passes as its components; H is rebuilt with the new field type
-- (Note [Signatures follow the transformations] in
-- GHC.WebCore.HiddenFields).  Also a record type (its selectors are
-- bindings of this module) and a type with a derived Show instance, whose
-- dictionary is exported but names the type only.
module Main (main) where

data H = H Int ((Int, Int) -> Int)

f1, f2 :: (Int, Int) -> Int
f1 (a, b) = a + b
{-# NOINLINE f1 #-}
f2 (a, b) = a * b
{-# NOINLINE f2 #-}

use :: H -> Int
use (H n g) = g (n, n + 1)
{-# NOINLINE use #-}

data Rec = Rec { rn :: Int, rf :: (Int, Int) -> Int }

useRec :: Rec -> Int
useRec r = rf r (rn r, 10)
{-# NOINLINE useRec #-}

data Sh = Sh Int ((Int, Int) -> Int) Bool

instance Show Sh where
  show (Sh n g b) = "Sh " ++ show (g (n, n)) ++ " " ++ show b

main :: IO ()
main = do
  print (use (H 3 f1) + use (H 4 f2))
  print (useRec (Rec 5 f1), useRec (Rec { rn = 6, rf = f2 }))
  print [Sh 2 f1 True, Sh 3 f2 False]
