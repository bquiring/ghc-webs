-- Dead parameters and seq: the web's only parameter is dead, and its
-- function values are forced (seq) before being called.  A lambda whose
-- body is an error must stay a lambda (unit, not deleted): forcing it must
-- not raise the error.
module Main (main) where

force :: (Int -> Int) -> Int
force h = h `seq` 7
{-# NOINLINE force #-}

choose :: Bool -> (Int -> Int)
choose b = if b then (\_ -> errorWithoutStackTrace "useless010: body") else (\_ -> 3)
{-# NOINLINE choose #-}

main :: IO ()
main = print (force (choose True), force (choose False))
