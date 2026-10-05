-- WORKING-THE-WORKER-WRAPPER.md, approach 1 (what GHC does today), when g is
-- cheap: g returns f, whose second argument is dead; GHC inlines g at the
-- call site and duplicates f's body at every call of h.  The body calls
-- 'marker', so the dump shows one call of marker per call of h (two), and
-- no g.
module WWReturn001 (run) where

marker :: Int -> Int
marker x = x
{-# NOINLINE marker #-}

g :: Int -> (Int -> Int -> Int)
g n = let k = n * n + 1
          f x y = marker (x * x + k * x)   -- y dead
      in f

run :: Int -> Int -> Int -> Int -> Int
run n a b c = let h = g n in h a b + h b c
