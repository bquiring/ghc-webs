-- Functions stored in a local data structure, called with a poison argument
-- they ignore. (Deadness and strictness: the program must behave as it does
-- unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

data Ops = Ops (Int -> Int -> Int) (Int -> Int -> Int)

ops :: Ops
ops = Ops (\a _ -> a + 1) (\a _ -> a * 2)
{-# NOINLINE ops #-}

run :: Ops -> Int -> Int
run (Ops f g) n = f n (poison "stored f") + g n (poison "stored g")
{-# NOINLINE run #-}

main :: IO ()
main = print (run ops 10)
