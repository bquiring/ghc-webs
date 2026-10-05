-- Known-argument elimination is not constant propagation: every call of the
-- web passes the same *local* variable x, but x is a different value in each
-- activation of 'run', and is not in scope where the lambdas are defined.
-- So it must not be propagated (only closed constants are).  This test fails
-- if it is (Core Lint: x out of scope; or the wrong result).
module Main (main) where

apply :: (Int -> Int) -> Int -> Int
apply f x = f x + f x
{-# NOINLINE apply #-}

run :: Int -> Int
run n = let x = n * 3 in apply sq x + apply inc x
{-# NOINLINE run #-}

sq, inc :: Int -> Int
sq y = y * y
inc y = y + 1
{-# NOINLINE sq #-}
{-# NOINLINE inc #-}

main :: IO ()
main = print (map run [1, 2, 3])
