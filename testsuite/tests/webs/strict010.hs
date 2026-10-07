-- Laziness: as strict009, but one function that reaches f ignores its
-- argument, which diverges.  The web of pass's second lambda is then lazy
-- too, and apply must not evaluate the argument.  This test fails if the
-- fixpoint makes a web strict through a lazy one.
module Main (main) where

g :: Int -> Int
g n = if n > 5 then error "strict010: argument evaluated" else n
{-# NOINLINE g #-}

pass :: (Int -> Int) -> Int -> Int
pass f n = f n
{-# NOINLINE pass #-}

apply :: ((Int -> Int) -> Int -> Int) -> (Int -> Int) -> Int -> Int
apply p f n = p f (g n)
{-# NOINLINE apply #-}

sq, ignore :: Int -> Int
sq x = x * x
ignore _ = 7
{-# NOINLINE sq #-}
{-# NOINLINE ignore #-}

main :: IO ()
main = print (apply pass sq 3, apply pass ignore 10)
