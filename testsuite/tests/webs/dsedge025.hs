-- Dead fields in recursive types, next to unboxable ones (the shape of nofib
-- spectral/rewrite, Note [Demands after flattening]): a node's tag only
-- feeds the tags of the nodes built from it, so it is dropped, and its pair
-- is unpacked, while functions strict in the nodes have demand signatures
-- from before either change.  Eqn is recursive through a list, Node through
-- itself (and is infinite).
module Main (main) where

data Expr = Lit Int | Add Expr Expr | Mul Expr Expr

eval :: Expr -> Int
eval (Lit n)   = n
eval (Add a b) = eval a + eval b
eval (Mul a b) = eval a * eval b

data Eqn = Eqn Int (Expr, Expr) [Eqn]

grow :: Int -> Eqn -> Eqn
grow 0 e                 = e
grow k (Eqn t (l, r) cs) =
  Eqn (t + 1) (Add l (Lit k), Mul r (Lit 2))
      (map (grow (k - 1)) (Eqn (t * 2) (r, l) [] : cs))
{-# NOINLINE grow #-}

weigh :: Eqn -> Int
weigh (Eqn _ (l, r) cs) = (eval l - eval r) `mod` 1009 + sum (map weigh cs)
{-# NOINLINE weigh #-}

data Node = Node Int (Int, Int) Node

fib :: Int -> (Int, Int) -> Node
fib t (a, b) = Node t (a, b) (fib (t + 1) (b, (a + b) `mod` 10007))
{-# NOINLINE fib #-}

at :: Int -> Node -> Int
at 0 (Node _ (a, _) _) = a
at k (Node _ _ n)      = at (k - 1) n
{-# NOINLINE at #-}

main :: IO ()
main = do
  print (weigh (grow 4 (Eqn 0 (Lit 1, Lit 2) [])))
  print (at 30 (fib 0 (0, 1)), at 500 (fib 7 (3, 4)))
