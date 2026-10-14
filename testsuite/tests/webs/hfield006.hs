-- A type synonym that mentions a type with hidden fields does not keep its
-- fields exposed: the synonym's uses are expanded wherever they mention the
-- rebuilt type (Note [Signatures follow the transformations] in
-- GHC.WebCore.HiddenFields).  nofib constraints lost 15% when its
-- synonyms over CSP kept CSP's field webs exposed.
module Main (main) where

data Csp = Csp Int (Int -> Int -> Bool)

type Check = Csp -> Int -> Bool
type Pair = (Csp, Csp)

mk :: Int -> Csp
mk n = Csp n (\a b -> (a + b) `mod` n == 0)
{-# NOINLINE mk #-}

check :: Check
check (Csp n rel) k = rel k (n - k)
{-# NOINLINE check #-}

both :: Pair -> Int -> Int
both (c1, c2) k = length [ () | i <- [0 .. k], check c1 i, check c2 i ]
{-# NOINLINE both #-}

main :: IO ()
main = print (sum [ both (mk 7, mk 5) k | k <- [1 .. 200] ])
