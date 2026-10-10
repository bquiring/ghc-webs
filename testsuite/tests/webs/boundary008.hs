-- Note [Captured dictionaries] (GHC.WebCore.Transform.Defunc): reach is
-- exported, so its wrapper passes \p -> r p to the local copy; component
-- passes edgesFrom es, which captures the Eq dictionary.  The two lambdas
-- share a web, which is not defunctionalised: a dictionary cannot be an
-- ordinary field.  (From nofib spectral/scc, which panicked.)
module Main (main, reach, component) where

reach :: Eq v => (v -> [v]) -> [v] -> v -> [v]
reach r seen x
  | x `elem` seen = seen
  | otherwise     = foldl (reach r) (x : seen) (r x)

edgesFrom :: Eq v => [(v, v)] -> v -> [v]
edgesFrom es w = [ y | (x, y) <- es, x == w ]

component :: Eq v => [(v, v)] -> v -> [v]
component es x = reach (edgesFrom es) [] x
{-# NOINLINE component #-}

main :: IO ()
main = print (component [(1, 2), (2, 3), (3, 1), (4, 5 :: Int)] 1)
