-- WORKING-THE-WORKER-WRAPPER.md, approach 1, when g cannot be inlined (it
-- does work, k, before returning f, and the partial applications g n and
-- g m are shared): GHC does not split g.  g returns  \x _ -> ...  with the dead
-- argument still there, and every call of h still passes it, boxed.
-- Approach 2 would split g itself:
--     $wg n = let k = ... in \x# -> ...   (dead argument gone)
--     g n   = let f' = $wg n in \x _ -> f' x
-- so that, after inlining g,  h1 = $wg n  and the calls are  h1 a# , h1 b#.
module WWReturn002 (run) where

g :: Int -> (Int -> Int -> Int)
g n = let k = sum [1 .. n]
          f x y = x * x + k * x + 12345   -- y dead
      in f

run :: Int -> Int -> Int -> Int -> Int
run n m a b = let h1 = g n
                  h2 = g m
              in h1 a b + h1 b a + h2 a b + h2 b a
