-- Note [Result raising]: a raised call scrutinised by a case whose binder
-- is used and one of whose field binders is a wildcard.  The case binder
-- is rebuilt from the field binders (let b = K ys), and the wildcard's
-- "dead" occurrence info must be zapped (Web Lint: "Occurrence of a dead
-- Id"; found building happy's generated parser).
module Main (main) where

data P = P Int Int deriving Show

apply :: (Int -> P) -> [Int] -> [P]
apply f xs = [ case f x of b@(P a _) -> if a > 3 then b else P a a | x <- xs ]
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply (\x -> P (x * 2) (x + 1)) [1 .. 4], apply (\x -> P x x) [5, 1])
