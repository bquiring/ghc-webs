{-# LANGUAGE MagicHash #-}
-- Laziness: the argument of a partial application is unlifted, so it is
-- evaluated when the partial application is, and here it throws.  The
-- eta-expanded partial application must still evaluate it.  This test fails
-- if the argument is moved under the new lambda.
module Main (main) where

import Control.Exception
import GHC.Exts

applyU :: (Int# -> Int -> Int) -> Int -> (Int -> Int)
applyU f n = f (boom n)
{-# NOINLINE applyU #-}

boom :: Int -> Int#
boom n = if n > 100 then 1# else error "argument evaluated"
{-# NOINLINE boom #-}

g :: Int# -> Int -> Int
g a b = I# a + b
{-# NOINLINE g #-}

main :: IO ()
main = do
  r <- try (evaluate (applyU g 5))
  putStrLn (either (\(ErrorCall m) -> m) (const "no exception") r)
  print (applyU g 200 41)
