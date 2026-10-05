-- Higher-order worker/wrapper (-fworker-wrapper-function-results).
-- Sharing: the work g does before returning its function (k, traced) is
-- done once per partial application h, not once per call of h: the trace
-- prints twice (once for g 10, once for g 20), not four times.
import Debug.Trace

g :: Int -> (Int -> Int -> Int)
g n = let k = trace "k" (sum [1 .. n])
          f x y = x * x + k * x + 7      -- y dead
      in f

run :: Int -> Int -> Int -> Int -> Int
run n m a b = let h1 = g n
                  h2 = g m
              in h1 a b + h1 b a + h2 a b + h2 b a
{-# NOINLINE run #-}

main :: IO ()
main = print (run 10 20 3 4)
