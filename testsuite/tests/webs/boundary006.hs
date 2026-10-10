-- Note [Eta-expanding parameters at the boundary]: applyAll is exported, so
-- its parameter f is exposed.  The wrapper passes \p -> f p to the local
-- copy, whose parameter web then holds only that lambda and main's two: it
-- is internal, and defunctionalised.
module Main (main, applyAll) where

applyAll :: (Int -> Int) -> [Int] -> Int
applyAll _ []     = 0
applyAll f (x:xs) = f x + applyAll f xs

main :: IO ()
main = print (applyAll (\x -> x * 2) [1..10], applyAll (+1) [1..5])
