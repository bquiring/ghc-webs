-- One-shot lambdas from webs (Note [One-shot lambdas from webs]).  apply
-- passes  \x -> x + n  to g, an unknown function, so demand analysis cannot
-- see how often it is called; its web can: every k uses it once, so it is
-- one-shot.  apply2's lambda is called twice by one of its consumers, so it
-- is not.  (The lambdas have a free variable, n: a closed lambda is floated
-- to the top level, where one value serves every call of apply.)
module Main (main) where

apply :: Int -> ((Int -> Int) -> Int) -> Int
apply n g = g (\x -> x + n)
{-# NOINLINE apply #-}

apply2 :: Int -> ((Int -> Int) -> Int) -> Int
apply2 n g = g (\y -> y * n)
{-# NOINLINE apply2 #-}

main :: IO ()
main = do
  print (apply 1 (\k -> k 5) + apply 1 (\k -> k 6 * 2))
  print (apply2 3 (\k -> k 1) + apply2 3 (\k -> k 1 + k 2))
