-- A result component one caller forces and another does not: lazy at the
-- producer. The poison reaches only the lazy caller. (Deadness and
-- strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

apply1, apply2 :: (Int -> (Int, Int)) -> Int -> Int
apply1 f n = case f n of (a, b) -> a + b
apply2 f n = case f n of (a, _) -> a
{-# NOINLINE apply1 #-}
{-# NOINLINE apply2 #-}

mk :: Int -> (Int, Int)
mk n = (n, if n > 100 then poison "lazily consumed second" else n * 2)
{-# NOINLINE mk #-}

main :: IO ()
main = print (apply1 mk 3, apply2 mk 500)
