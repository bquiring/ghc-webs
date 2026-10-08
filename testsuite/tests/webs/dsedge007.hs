-- GADTs and existentials are not split; lists inside them, and lists of
-- them, must still be handled correctly.
{-# LANGUAGE GADTs, ExistentialQuantification #-}
module Main (main) where

data Some = forall a. Show a => Some [(a, a)]

data T a where
  TI :: [(Int, Int)] -> T Int
  TB :: Bool -> T Bool

describe :: Some -> String
describe (Some ps) = show (length ps) ++ ":" ++ show (take 1 ps)
{-# NOINLINE describe #-}

eval :: T a -> a
eval (TI ps) = sum [ x * y | (x, y) <- ps ]
eval (TB b)  = not b
{-# NOINLINE eval #-}

main :: IO ()
main = do
  mapM_ (putStrLn . describe) [ Some [(1 :: Int, 2 :: Int)], Some [("a", "b"), ("c", "d")] ]
  print (eval (TI [ (i, i + 1) | i <- [1 .. 10] ]))
  print (eval (TB False))
