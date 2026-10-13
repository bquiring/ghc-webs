-- Useless elimination reached a fixpoint only at its round limit: a dead
-- field of a scrutinised construction that the rewrite cannot fill (P's
-- strict first field; Q's first field needs evaluation) counted as a
-- change in every round.  The pass must settle in one round.
module Main (main) where

data P = P !Int Int
data Q = Q Int Int
g :: Bool -> Int -> Int
g b n = case (case b of { True -> P n (n + 1); False -> P (n * 2) 7 }) of P _ y -> y
{-# NOINLINE g #-}
h :: Bool -> Int -> Int
h b n = case (case b of { True -> Q (n `div` 0) n; False -> Q (n `div` 0) 7 }) of Q _ y -> y
{-# NOINLINE h #-}
main :: IO ()
main = print (g True 3, g False 3, h True 4, h False 4)
