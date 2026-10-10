-- A record whose poison field is overwritten before it is read. (Deadness
-- and strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

data R = R { ra :: Int, rb :: Int }

initial :: R
initial = R { ra = 1, rb = poison "initial rb" }
{-# NOINLINE initial #-}

step :: R -> R
step r = r { rb = ra r * 10 }
{-# NOINLINE step #-}

main :: IO ()
main = print (rb (step initial), ra initial)
