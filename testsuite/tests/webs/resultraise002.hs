-- Laziness: a call of a raised web is bound by a lazy let and never forced
-- when n is small; the function's first component diverges.  The re-boxing
-- case must stay inside the thunk, and the components must stay lazy.  This
-- test fails if the call or its components are evaluated early.
module Main (main) where

use :: (Int -> (Int, Int)) -> Int -> Int
use f n = let r = f n in if n > 5 then snd r else n
{-# NOINLINE use #-}

useBoth :: (Int -> (Int, Int)) -> Int -> Int
useBoth f n = case f n of (_, b) -> b * 2
{-# NOINLINE useBoth #-}

p :: Int -> (Int, Int)
p n = if n > 1000 then error "resultraise002: call evaluated" else (error "resultraise002: component evaluated", n)
{-# NOINLINE p #-}

main :: IO ()
main = print (use p 3, use p 7, useBoth p 4)
