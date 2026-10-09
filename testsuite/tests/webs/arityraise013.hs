-- Constructed arguments (Note [Arity raising]): every call of k passes an
-- explicit pair, so its web is raised although one continuation is lazy in
-- the pair and another keeps it boxed.  The components stay lazy: the
-- errors are never forced.
module Main (main) where

withPair :: Int -> ((Int, Int) -> r) -> r
withPair n k = k (n + 1, n * 2)
{-# NOINLINE withPair #-}

withBad :: ((Int, Int) -> r) -> r
withBad k = k (error "first", error "second")
{-# NOINLINE withBad #-}

main :: IO ()
main = do
  print (withPair 3 (\(a, b) -> a + b))
  print (length (withPair 4 (\p -> [p, p])))
  print (withBad (\_ -> 7 :: Int))
  print (length (withBad (\p -> [p])))
