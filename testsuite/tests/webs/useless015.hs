-- Note [Useless elimination]: a tail call of another web returns more
-- components than the caller's lambda now does, and is adapted
-- (case call of (# ys #) -> (# live ys #)).  inner's second component is
-- used elsewhere (live); outer's is not.  The dead components are errors.
{-# LANGUAGE UnboxedTuples #-}
module Main (main) where

applyOuter :: (Int -> (# Int, Int #)) -> [Int] -> Int
applyOuter f xs = sum [ case f x of (# a, _ #) -> a | x <- xs ]
{-# NOINLINE applyOuter #-}

applyInner :: (Int -> (# Int, Int #)) -> [Int] -> Int
applyInner g xs = sum [ case g x of (# a, b #) -> a + b | x <- xs ]
{-# NOINLINE applyInner #-}

inner :: Int -> (# Int, Int #)
inner x = (# x * 2, x + 1 #)
{-# NOINLINE inner #-}

main :: IO ()
main = do
  print (applyInner inner [1..4], applyInner (\x -> (# x, x #)) [1..4])
  print (applyOuter (\x -> if x > 3 then inner x else (# x, errorWithoutStackTrace "useless015: dead" #)) [1..6])
