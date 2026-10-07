-- Note [Splitting webs at the boundary], part 2: g is passed to the
-- imported zipWith, and to the local apply2.  Its second argument is dead
-- at both, but zipWith's web is exposed.  Eta-expanding the argument of
-- zipWith splits g's web from it, so g's dead argument goes.
module Main (main) where

apply2 :: (Int -> Int -> Int) -> Int -> Int
apply2 f n = f n n + f (n + 1) n
{-# NOINLINE apply2 #-}

run :: Int -> [Int] -> Int
run k xs = let g y _ = y * k + 1
           in sum (zipWith g xs xs) + apply2 g k
{-# NOINLINE run #-}

main :: IO ()
main = print (run 3 [1, 2, 3])
