-- Unboxing inside data structures (Note [Specialising split types],
-- Note [Flattening fields]): the local list of pairs is only used at
-- (Int, Int), so its copy is specialised to it, and the pairs, always
-- built explicitly and only taken apart, are unpacked into the cons cells.
module Main (main) where

mk :: Int -> Int -> [(Int, Int)]
mk a b = if a > b then [] else (a, a * a) : mk (a + 1) b
{-# NOINLINE mk #-}

sumP :: [(Int, Int)] -> Int
sumP []             = 0
sumP ((x, y) : r)   = x + y + sumP r
{-# NOINLINE sumP #-}

main :: IO ()
main = print (sumP (mk 1 1000))
