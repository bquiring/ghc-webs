-- Higher-order worker/wrapper (-fworker-wrapper-function-results).
-- Divergence: g n diverges before returning its function when n < 0, so
-- seq (g n) () must diverge.  The wrapper scrutinises the worker's result
-- with a case; with a let, g n would be a lambda and this would print False.
import Control.Exception

g :: Int -> (Int -> Int -> Int)
g n | n < 0     = error "wwfunres001: diverged"
    | otherwise = let k = sum [1 .. n]
                      f x y = x * x + k * x + 7      -- y dead
                  in f
{-# NOINLINE g #-}

main :: IO ()
main = do
  r <- try (evaluate (g (-1) `seq` ()))
  print (either (\(ErrorCall _) -> True) (const False) r)
  let h = g 10
  print (h 2 3 + h 4 5)
