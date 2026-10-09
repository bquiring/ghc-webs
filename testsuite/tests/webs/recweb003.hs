-- Both directions: S = (Int, S ->{w} S).  w's lambdas take an S apart and
-- build one, so argument and result raising would both meet w again inside
-- the product.
module Main (main) where

data S = S Int (S -> S)

inc :: S -> S
inc (S a f) = S (a + 1) f
{-# NOINLINE inc #-}

swapTo :: (S -> S) -> S -> S
swapTo g = \(S a _) -> S (a * 3 `mod` 1009) g
{-# NOINLINE swapTo #-}

iter :: Int -> S -> Int
iter 0 (S a _)     = a
iter k s@(S _ f)   = iter (k - 1) (f s)
{-# NOINLINE iter #-}

main :: IO ()
main = do
  print (iter 10 (S 0 inc))
  print (iter 9 (S 2 (swapTo inc)), iter 9 (S 2 (swapTo (swapTo inc))))
