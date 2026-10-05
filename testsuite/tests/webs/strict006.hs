-- Laziness: two callers of the web; one uses the first field, the other
-- ignores it.  'run' passes the same function to both, so they share a web.
-- A function of the web returns a diverging first field, and only reaches
-- the second caller at run time.  The field is not strict at every call, so
-- the definition must not evaluate it.  This test fails if it does.
module Main (main) where

good, bad :: Int -> (Int, Int)
good n = (n + 1, n + 2)
bad n = (error "strict006: field evaluated", n)
{-# NOINLINE good #-}
{-# NOINLINE bad #-}

useFirst :: (Int -> (Int, Int)) -> Int -> Int
useFirst f n = case f n of (a, b) -> a + b
{-# NOINLINE useFirst #-}

useSecond :: (Int -> (Int, Int)) -> Int -> Int
useSecond f n = case f n of (_, b) -> b
{-# NOINLINE useSecond #-}

run :: (Int -> (Int, Int)) -> Bool -> Int -> Int
run f b n = if b then useFirst f n else useSecond f n
{-# NOINLINE run #-}

main :: IO ()
main = print (run good True 1, run bad False 5)
