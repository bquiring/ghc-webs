-- Note [Scrutinised constructions]: a lazy field the pattern ignores
-- becomes an absent filler; its value is an error (and a trace) that must
-- never be evaluated.  The constructions are spread over several tails
-- (cases, a let, a join point).
module Main (main) where

import Debug.Trace

data R = R Int Int

pick :: Int -> Int
pick x =
  case (let k = x * 2 in
        if x > 10 then R k (trace "useless016: traced field" k)
        else if x > 5 then R (k + 1) (errorWithoutStackTrace "useless016: field")
        else R x x) of
    R a _ -> a + 1
{-# NOINLINE pick #-}

main :: IO ()
main = print (map pick [1, 6, 12])
