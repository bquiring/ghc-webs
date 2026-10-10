-- Note [Eta-expanding parameters at the boundary]: the wrapper of the
-- exported applyBoth eta-expands its parameter f, which has two arrows.  The
-- partial application f n is shared in applyBoth, and must stay shared:
-- \x -> let r = f x in \y -> r y, not \x y -> f x y.  The last parameter is
-- dead, so the local copy changes and the split is kept.
module Boundary007A (applyBoth) where

applyBoth :: (Int -> Int -> Int) -> Int -> Int -> Int
applyBoth f n _ = let g = f n in g 1 + g 2
