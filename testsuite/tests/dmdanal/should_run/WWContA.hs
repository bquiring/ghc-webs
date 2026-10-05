{-# LANGUAGE BangPatterns #-}
module WWContA (Expr (..), evalK) where

data Expr = Lit Int | Add Expr Expr | Sub Expr Expr | Mul Expr Expr | Div Expr Expr

-- The continuation gets the value, and (depth, width) of the expression;
-- width of a division by zero is an error, forced only if used
evalK :: Expr -> Int -> (Int -> (Int, Int) -> r) -> r
evalK (Lit n) !d k = k (n + d * 0) (d, 1)
evalK (Add a b) !d k = evalK a (d + 1) (\x (da, wa) -> evalK b (d + 1) (\y (db, wb) -> k (x + y) (max da db, wa + wb)))
evalK (Sub a b) !d k = evalK a (d + 1) (\x (da, wa) -> evalK b (d + 1) (\y (db, wb) -> k (x - y) (max da db, wa + wb)))
evalK (Mul a b) !d k = evalK a (d + 1) (\x (da, wa) -> evalK b (d + 1) (\y (db, wb) -> k (x * y) (max da db, wa + wb)))
evalK (Div a b) !d k = evalK a (d + 1) (\x (da, wa) -> evalK b (d + 1) (\y (db, wb) ->
                         if y == 0 then k 0 (max da db, error "width of a division by zero")
                                   else k (x `div` y) (max da db, wa + wb)))
