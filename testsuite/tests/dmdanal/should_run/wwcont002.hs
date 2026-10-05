{-# LANGUAGE BangPatterns #-}
-- (Constructed) across modules, in CPS style: an evaluator whose
-- continuation always receives an I# and a pair, called with known and
-- unknown continuations.  [+] evalK.
module Main (main) where

import WWContA

main :: IO ()
main = do
  let e = Add (Mul (Lit 3) (Lit 4)) (Sub (Lit 10) (Lit 2))
  print (evalK e 0 (\v (d, w) -> v * 100 + d * 10 + w))
  print (evalK e 5 (\v _ -> v))
  print (evalK (Div (Lit 7) (Lit 0)) 0 (\v _ -> v))       -- the error field is never forced
  print (evalK (Div (Lit 7) (Lit 0)) 0 (\_ (d, _) -> d))
  print (sum [ evalK (Add (Lit i) (Lit 1)) i k | i <- [1 .. 5], k <- ks ])
  where
    ks = [\v _ -> v, \v (d, _) -> v + d, \_ (_, w) -> w]
