-- Laziness: an irrefutable pattern does not force the pair.  The web must
-- be rejected.  This test fails if it is raised.
module Main (main) where

useU :: ((Int, Int) -> Int) -> (Int, Int) -> Int
useU f p = f p
{-# NOINLINE useU #-}

lazyPat :: (Int, Int) -> Int
lazyPat ~(_, _) = 1
{-# NOINLINE lazyPat #-}

main :: IO ()
main = print (useU lazyPat undefined)
