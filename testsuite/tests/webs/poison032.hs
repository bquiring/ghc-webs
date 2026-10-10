-- A thunk captured by a closure that is never called. (Deadness and
-- strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

mkClosures :: Int -> (Int, Int -> Int)
mkClosures n = let t = poison "captured" + n in (n + 1, \k -> k + t)
{-# NOINLINE mkClosures #-}

main :: IO ()
main = print (fst (mkClosures 4))
