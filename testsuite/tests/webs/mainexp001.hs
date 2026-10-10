-- Note [Main's exports] in GHC.WebCore.Pipeline: a Main module with no
-- export list exports addP, but nothing imports Main.  With
-- -fcore-webs-internal-main-exports, addP is not kept, so the web of the
-- function passed to apply (addP and mulP) is internal and raised (the
-- dump); without the flag it is exposed.
module Main where

addP :: (Int, Int) -> Int
addP (a, b) = a + b
{-# NOINLINE addP #-}

mulP :: (Int, Int) -> Int
mulP (a, b) = a * b
{-# NOINLINE mulP #-}

apply :: ((Int, Int) -> Int) -> Int -> Int
apply f n = f (n, n + 1)
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply addP 3 + apply mulP 4)
