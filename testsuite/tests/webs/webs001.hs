-- Higher-order functions: two local functions flow to the same call site in
-- 'apply', so their webs, the webs of apply's argument, and the web of the
-- call (f x) must all be merged into one class.  'neg' never flows to 'apply',
-- so its web stays separate.
module Main (main) where

apply :: (Int -> Int) -> Int -> Int
apply f x = f x + 1
{-# NOINLINE apply #-}

inc :: Int -> Int
inc x = x + 1
{-# NOINLINE inc #-}

dbl :: Int -> Int
dbl x = x * 2
{-# NOINLINE dbl #-}

neg :: Int -> Int
neg x = negate x
{-# NOINLINE neg #-}

main :: IO ()
main = do
  print (apply inc 10)
  print (apply dbl 10)
  print (neg 10)
