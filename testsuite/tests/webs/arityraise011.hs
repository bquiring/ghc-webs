-- Laziness: the functions are strict in the pair, and the argument is
-- 'undefined'.  After raising, the caller forces the argument instead of the
-- callee, but the exception must still be thrown.
module Main (main) where

import Control.Exception

useU :: ((Int, Int) -> Int) -> (Int, Int) -> Int
useU f p = f p
{-# NOINLINE useU #-}

addP :: (Int, Int) -> Int
addP (a, b) = a + b
{-# NOINLINE addP #-}

main :: IO ()
main = do
  r <- try (evaluate (useU addP undefined))
  putStrLn (either (\(ErrorCall _) -> "exception") show r)
  print (useU addP (20, 22))
