-- An abstract type: H is exported, its constructor is not, so its fields
-- are hidden (Note [Hidden fields] in GHC.WebCore.Sigs) although exported
-- functions name H.  If arity raising changes the field's web, H is rebuilt
-- in place, and the interface must describe the rebuilt H: hfield002
-- inlines these functions, and their unfoldings match on H.
module HField002A (H, mkAdd, mkMul, useH) where

data H = H Int ((Int, Int) -> Int)

add, mul :: (Int, Int) -> Int
add (a, b) = a + b
{-# NOINLINE add #-}
mul (a, b) = a * b
{-# NOINLINE mul #-}

mkAdd, mkMul :: Int -> H
mkAdd n = H n add
mkMul n = H n mul

useH :: H -> Int
useH (H n g) = g (n, n + 1)
