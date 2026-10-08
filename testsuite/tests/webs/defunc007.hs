-- A lambda whose free variables' types mention a type variable its body does
-- not: in  \x -> k (g x)  the type s appears only in the types of k and g.
-- The constructor must still bind s as an existential (it was out of scope
-- in the apply function's alternative; real/veritas, spectral/dom-lt).
-- main passes apply a second lambda, so that the web has two (a web with
-- one lambda is not defunctionalised).
module Main (main) where

data Box s = Box (s -> Int) (Int -> s)

viaBox :: Box s -> Int
viaBox (Box k g) = apply (\x -> k (g x))
{-# NOINLINE viaBox #-}

apply :: (Int -> Int) -> Int
apply f = f 1 + f 2
{-# NOINLINE apply #-}

main :: IO ()
main = do
  print (viaBox (Box (* 2) (+ 1)))
  print (viaBox (Box length (`replicate` 'x')))
  print (apply (\x -> x * 10))
