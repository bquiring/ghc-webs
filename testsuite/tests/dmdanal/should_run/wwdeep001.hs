-- Higher-order worker/wrapper (-fworker-wrapper-function-results), three
-- levels of returned functions with a dead argument at the deepest.  The
-- traces (one per partial application at each level) must be unchanged.
module Main (main) where
import WWDeepA

run1 :: Int -> [Int] -> Int
run1 n xs = let h1 = g3 n
                h2 = h1 2
                h3 = h2 3
            in sum (map (\x -> h3 x 0) xs) + sum (map (\x -> h2 x x 0) xs)
{-# NOINLINE run1 #-}

run2 :: Int -> [Int] -> Int
run2 n xs = sum [ g3 n a a a 0 | a <- xs ]
{-# NOINLINE run2 #-}

main :: IO ()
main = print (run1 10 [1 .. 5], run2 20 [1 .. 3])
