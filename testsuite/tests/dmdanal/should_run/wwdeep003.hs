-- Higher-order worker/wrapper: five levels of returned functions, deeper
-- than the split looks; the result must be unchanged.
module Main (main) where
import WWDeepA

run :: Int -> [Int] -> Int
run n xs = let h = g6 n 1 2 3 4 in sum (map (\x -> h x 0) xs)
{-# NOINLINE run #-}

main :: IO ()
main = print (run 10 [1 .. 5])
