{-# LANGUAGE MagicHash #-}
-- Laziness: the dropped argument has an unlifted type (Int#), so it was
-- evaluated before the call, and here its evaluation throws.  Deleting the
-- parameter must not lose that evaluation.  This test fails if the
-- evaluation is dropped along with the argument (it would print 10).
module Main (main) where

import Control.Exception
import GHC.Exts

applyU :: (Int# -> Int) -> Int -> Int
applyU f n = f (boom n)
{-# NOINLINE applyU #-}

boom :: Int -> Int#
boom n = if n > 100 then 1# else error "argument evaluated"
{-# NOINLINE boom #-}

c1 :: Int# -> Int
c1 _ = 10
{-# NOINLINE c1 #-}

main :: IO ()
main = do
  r <- try (evaluate (applyU c1 5))
  putStrLn (either (\(ErrorCall m) -> m) show r)
  print (applyU c1 200)
