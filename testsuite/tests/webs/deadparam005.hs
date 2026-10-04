{-# LANGUAGE MagicHash #-}
-- The functions return Int#, an unlifted result: deleting the parameter
-- would make an unlifted binding, evaluated eagerly.  The web becomes a unit
-- web instead.
module Main (main) where

import GHC.Exts

applyH :: (Int -> Int#) -> Int
applyH f = I# (f 0 +# f 1)
{-# NOINLINE applyH #-}

h1 :: Int -> Int#
h1 _ = 3#
{-# NOINLINE h1 #-}

h2 :: Int -> Int#
h2 _ = 4#
{-# NOINLINE h2 #-}

main :: IO ()
main = print (applyH h1 + applyH h2)
