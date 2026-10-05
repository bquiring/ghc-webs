-- Higher-order worker/wrapper through a newtype (-fworker-wrapper-function-results):
-- a state-monad-like newtype over a function.  mkCounter does work, then
-- returns a State whose function is strict in its Int state and has a dead
-- second argument; the tails are casts  (\s z -> ..) |> co.  The split looks
-- through the casts: the worker returns the function's worker (unboxed
-- state, no dead argument), and the wrapper casts back.
module Main (main) where

newtype Step = Step (Int -> Int -> (Int, Int))

runStep :: Step -> Int -> (Int, Int)
runStep (Step f) s = f s 0

mkCounter :: Int -> Step
mkCounter n = let k = sum [1 .. n]
              in Step (\s _z -> let s' = s * 3 + k in s' `seq` (s' `mod` 1000, s' - k))

loop :: Step -> Int -> Int -> Int
loop st 0 acc = acc
loop st i acc = case runStep st (acc + i) of (a, b) -> loop st (i - 1) (a + b `mod` 97)

main :: IO ()
main = print (loop (mkCounter 10) 1000 0, loop (mkCounter 3) 500 1, fst (runStep (mkCounter 5) 7))
