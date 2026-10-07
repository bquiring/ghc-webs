-- Curried lambdas: the lambdas of op's outer web return lambdas of an inner
-- web.  Both webs are defunctionalised: the inner constructors capture the
-- outer lambdas' parameter.  The partial application  op 3  is shared and
-- called twice.  (The lambdas must not eta-reduce to an imported function,
-- such as (+), whose web is exposed.)
module Main (main) where

both :: (Int -> Int -> Int) -> Int
both op = let g = op 3 in g 4 + g 5
{-# NOINLINE both #-}

main :: IO ()
main = print (both (\a b -> a * 10 + b), both (\a b -> a - 2 * b))
