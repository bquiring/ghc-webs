-- Note [Arguments of unknown calls]: the continuation web of k takes an Int
-- and an 8-field record that both its lambdas are strict in.  Raising it
-- would make the unknown call  k i r  pass 9 arguments; with
-- -fcore-webs-raise-max-args=6 the web is rejected (arityraise014_max),
-- without a bound it is raised (arityraise014_dump).  Same output either way.
module Main (main) where

data R = R !Int !Int !Int !Int !Int !Int !Int !Int

run :: Int -> (Int -> R -> Int) -> Int
run n k = k n (R n (n+1) (n+2) (n+3) (n+4) (n+5) (n+6) (n+7))
{-# NOINLINE run #-}

main :: IO ()
main = do
  print (run 1 (\i (R a b c d e f g h) -> i + a + b + c + d + e + f + g + h))
  print (run 2 (\i (R a _ _ _ _ _ _ h) -> i * a * h))
