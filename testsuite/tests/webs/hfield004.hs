-- Note [Signatures in the program] in GHC.WebCore.HiddenFields: the
-- field's web takes a pair at every use in the program, but the
-- definition's field takes one polymorphic parameter, so the web must not
-- be raised (Web Lint stopped compilation when the analyses did not see the
-- definition).
module Main (main) where

data P a = P Int (a -> Int)

f1, f2 :: (Int, Int) -> Int
f1 (a, b) = a + b
{-# NOINLINE f1 #-}
f2 (a, b) = a * b
{-# NOINLINE f2 #-}

use :: P (Int, Int) -> Int
use (P n g) = g (n, n + 1)
{-# NOINLINE use #-}

main :: IO ()
main = print (use (P 3 f1) + use (P 4 f2))
