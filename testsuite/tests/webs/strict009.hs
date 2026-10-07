-- Strict arguments through an unknown call: 'pass' gives its argument only
-- to the unknown f, so demand analysis finds it lazy.  Every function that
-- reaches f is strict, so the web of pass's second lambda is strict
-- (Note [Web strictness fixpoints]), and apply evaluates (g n) before its
-- unknown call of p.
module Main (main) where

g :: Int -> Int
g n = n * 3 + 1
{-# NOINLINE g #-}

pass :: (Int -> Int) -> Int -> Int
pass f n = f n
{-# NOINLINE pass #-}

apply :: ((Int -> Int) -> Int -> Int) -> (Int -> Int) -> Int -> Int
apply p f n = p f (g n)
{-# NOINLINE apply #-}

sq, dbl :: Int -> Int
sq x = x * x
dbl x = x + x
{-# NOINLINE sq #-}
{-# NOINLINE dbl #-}

main :: IO ()
main = print (apply pass sq 3, apply pass dbl 4)
