-- Laziness: one function of the web ignores its argument, which diverges.
-- The web is lazy, so the call must not evaluate the argument.  This test
-- fails if the argument is evaluated at the call.
module Main (main) where

g :: Int -> Int
g n = if n > 5 then error "strict002: argument evaluated" else n
{-# NOINLINE g #-}

apply :: (Int -> Int) -> Int -> Int
apply f n = f (g n)
{-# NOINLINE apply #-}

sq, ignore :: Int -> Int
sq x = x * x
ignore _ = 7
{-# NOINLINE sq #-}
{-# NOINLINE ignore #-}

main :: IO ()
main = print (apply sq 3, apply ignore 10)
