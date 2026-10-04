-- Laziness: a curried function strict in its pair, but only once fully
-- applied.  The partial application  f undefined  is a value that never
-- forces the pair, so forcing it must terminate.  Raising would make the
-- caller take 'undefined' apart at the partial application, so the web must
-- be rejected (curried).  This test fails if it is raised.
module Main (main) where

forcePartial :: ((Int, Int) -> Int -> Int) -> ()
forcePartial f = f undefined `seq` ()
{-# NOINLINE forcePartial #-}

applyFull :: ((Int, Int) -> Int -> Int) -> Int
applyFull f = f (1, 2) 3
{-# NOINLINE applyFull #-}

curriedF :: (Int, Int) -> Int -> Int
curriedF (a, b) c = a + b + c
{-# NOINLINE curriedF #-}

main :: IO ()
main = print (forcePartial curriedF, applyFull curriedF)
