-- Mix: the shared partial application is both called and stored (it
-- escapes into a list and is forced with seq), and the returned function
-- contains a join point.
module Main (main) where

g :: Int -> (Int -> Int -> Int)
g n = let k = sum [1 .. n]
          f x y = let j z = (z * 1 + k) * (z - 1) + (z * 2 + k) * (z - 2) + (z * 3 + k) * (z - 3) + (z * 4 + k) * (z - 4) + (z * 5 + k) * (z - 5) in if x > 3 then j x else j (x * 2)   -- y dead
      in f
{-# NOINLINE run #-}

run :: Int -> [Int] -> (Int, Int)
run n xs = let h = g n
               hs = [h, g (n + 1)]
           in foldr seq () hs `seq` (sum (map (\x -> h x 0) xs), sum [ f 2 0 | f <- hs ])

main :: IO ()
main = print (run 10 [1 .. 6])
