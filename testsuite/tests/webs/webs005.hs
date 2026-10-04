{-# LANGUAGE TypeFamilies #-}
-- Boundary case: coercion axioms.  Functions cast through a newtype (local or
-- imported), a closed type family (a branched axiom), or an open type family
-- instance (an unbranched axiom) are involved in a coercion axiom, so their
-- webs are exposed (E in -ddump-webs-summary).  'plain' is never cast, so
-- its web stays local.
module Main (main) where

import Data.Monoid ( Endo(..) )

-- A local newtype over a function: axiom N:Fn
newtype Fn = Fn (Int -> Int)

runFn :: Fn -> Int -> Int
runFn (Fn f) x = f x
{-# NOINLINE runFn #-}

inc :: Int -> Int
inc x = x + 1
{-# NOINLINE inc #-}

-- An imported newtype over a function: axiom N:Endo
times3 :: Int -> Int
times3 x = x * 3
{-# NOINLINE times3 #-}

useEndo :: Endo Int -> Int
useEndo (Endo f) = f 5
{-# NOINLINE useEndo #-}

-- A closed type family: a branched axiom
type family Res a where
  Res Bool = Int -> Int
  Res Char = Int

viaClosed :: Res Bool
viaClosed x = x * 7
{-# NOINLINE viaClosed #-}

-- Consumers that keep the casts through the axioms alive
useRes :: Res Bool -> Int
useRes f = f 6
{-# NOINLINE useRes #-}

-- An open type family instance: an unbranched axiom
type family Open a
type instance Open Int = Int -> Int

viaOpen :: Open Int
viaOpen x = x - 1
{-# NOINLINE viaOpen #-}

useOpen :: Open Int -> Int
useOpen f = f 10
{-# NOINLINE useOpen #-}

-- Never cast: local
plain :: Int -> Int
plain x = x + 100
{-# NOINLINE plain #-}

callPlain :: (Int -> Int) -> Int
callPlain f = f 1
{-# NOINLINE callPlain #-}

main :: IO ()
main = do
  print (runFn (Fn inc) 1)
  print (useEndo (Endo times3))
  print (useRes viaClosed)
  print (useOpen viaOpen)
  print (callPlain plain)
