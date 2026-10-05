-- Higher-order worker/wrapper: something to gain at two levels (a dead
-- argument at level 1, a dead and a strict argument at level 3), split in
-- one pass.  Traces and results must be unchanged.
module Main (main) where
import WWDeepA

run :: Int -> [Int] -> Int
run n xs = let h1 = g4 n
               h2 = h1 5 undefined          -- the dead argument d
               h3 = h2 7
           in sum (map (\x -> h3 x undefined) xs)   -- the dead argument y
              + sum [ h1 x undefined x x undefined | x <- xs ]
{-# NOINLINE run #-}

main :: IO ()
main = print (run 10 [1 .. 4], run 3 [2, 3])
