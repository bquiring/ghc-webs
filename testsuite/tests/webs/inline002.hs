-- Laziness: the inlined function ignores its argument, which diverges.  The
-- argument is let-bound at the call, so it is never evaluated.  This test
-- fails if the inlined call evaluates its argument.
module Main (main) where

apply :: (Int -> Int) -> Int -> Int
apply f n = f (if n > 0 then error "inline002: argument evaluated" else n) + n
{-# NOINLINE apply #-}

five :: Int -> Int
five _ = 5

main :: IO ()
main = print (apply five 1, apply five 2)
