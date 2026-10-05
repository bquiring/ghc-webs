-- Laziness: a call of the web is bound by a lazy let and only its second
-- field is used, while the first field diverges.  The call is not scrutinised
-- by a case at that site, so no field is strict.  'run' passes the same
-- function to both callers, so they share a web.  This test fails if the
-- definition evaluates the first field.
module Main (main) where

good, bad :: Int -> (Int, Int)
good n = (n + 1, n + 2)
bad n = (error "strict007: field evaluated", n)
{-# NOINLINE good #-}
{-# NOINLINE bad #-}

useFirst :: (Int -> (Int, Int)) -> Int -> Int
useFirst f n = case f n of (a, b) -> a * b
{-# NOINLINE useFirst #-}

lazyUse :: (Int -> (Int, Int)) -> Int -> [Int]
lazyUse f n = let r = f n in [n, snd r]
{-# NOINLINE lazyUse #-}

run :: (Int -> (Int, Int)) -> Bool -> Int -> [Int]
run f b n = if b then [useFirst f n] else lazyUse f n
{-# NOINLINE run #-}

main :: IO ()
main = print (run good True 2, run bad False 9)
