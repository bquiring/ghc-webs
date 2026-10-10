-- A let-bound thunk used only in a branch the run never takes: strictness
-- must not hoist it. (Deadness and strictness: the program must behave as it
-- does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

f :: Int -> Int
f n = let t = poison "let in untaken branch" + n in if n < 0 then t else n * 2
{-# NOINLINE f #-}

main :: IO ()
main = print (map f [1 .. 5])
