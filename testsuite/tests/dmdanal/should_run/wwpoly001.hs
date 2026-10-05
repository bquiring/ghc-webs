-- Worker/wrapper through function arguments for polymorphic functions
-- (-fworker-wrapper-function-results; (TypeParams) in Note [Worker/wrapper
-- for function arguments]).  h has a type parameter (and a class
-- dictionary); it passes its local function, whose second argument is dead,
-- to g.  Used at Int and Double, and with g ignoring the dead argument, which
-- is undefined.
module Main (main) where

h :: Num a => ((a -> a -> a) -> a) -> a -> [a] -> a
h g s xs = let k = sum xs + s
               f x _y = x * x * k + x * s + k * k + x * 3 + s * s * x + 7   -- y dead
           in g f + f s s + sum (map (\x -> f x x) xs)

-- Plain polymorphism (no dictionary): the local function is passed to g
-- twice; its second argument is dead
pairUp :: (a -> b -> a) -> ((a -> Int -> a) -> c) -> a -> b -> [c]
pairUp op g a b = let step x _n = op (op x b) b
                  in [g step, g (\x n -> step (step x n) n)] ++ [g step | _ <- [1 .. length [a, a]]]

main :: IO ()
main = do
  print (h (\f -> f 2 undefined) (3 :: Int) [1 .. 10], h (\f -> f 1 0 + f 2 0) (3 :: Int) [4, 5])
  print (h (\f -> f 0.5 undefined) (1.5 :: Double) [1, 2])
  print (pairUp (++) (\s -> length (s "ab" 0)) "x" "yz", pairUp (+) (\s -> s 1 undefined) (2 :: Int) 3)
