-- Note [Demands after flattening] in GHC.WebCore.DataFlatten (nofib
-- spectral/rewrite).  Eqn's number only feeds the number of other Eqns, so
-- it is dropped (dead); its pair of expressions is unpacked in a later
-- round.  Eqn then has two fields again, and size's stale demand
-- signature, P(A, P(L, L)) from before, would give the first expression
-- the dropped number's absent demand: worker/wrapper would pass it as
-- absent, and the program would enter an absent argument.
module Main (main) where

data Expr = Lit Int | Add Expr Expr

data Eqn = Eqn Int (Expr, Expr)

swap :: Eqn -> Eqn
swap (Eqn n (l, r)) = Eqn (n + 1) (r, l)
{-# NOINLINE swap #-}

esize :: Expr -> Int
esize (Lit _)   = 1
esize (Add a b) = esize a + esize b

size :: Eqn -> Int
size (Eqn _ (l, r)) = esize l + 2 * esize r
{-# NOINLINE size #-}

eqns :: Int -> [Eqn]
eqns k = [ Eqn i (Add (Lit i) (Lit k), Lit i) | i <- [1 .. k] ]

main :: IO ()
main = print (sum (map (size . swap . swap . swap) (eqns 1000)))
