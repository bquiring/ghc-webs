-- Note [Scrutinised constructions]: a strict field keeps its value.  The
-- pattern ignores the second field of P, but P's second field is strict, so
-- building P evaluates it, and the error must still be raised.  Q's second
-- field is lazy: its error is never raised.
module Main (main) where

data P = P Int !Int
data Q = Q Int Int

mkP, mkQ :: Int -> Int
mkP x = case (if x > 0 then P x (errorWithoutStackTrace "useless007: strict field") else P 0 0) of
          P a _ -> a
mkQ x = case (if x > 0 then Q x (errorWithoutStackTrace "useless007: lazy field") else Q 0 0) of
          Q a _ -> a
{-# NOINLINE mkP #-}
{-# NOINLINE mkQ #-}

main :: IO ()
main = do
  print (mkQ 3)
  print (mkP 3)
