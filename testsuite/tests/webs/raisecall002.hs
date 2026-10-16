module Main (main) where

-- Moving a constructor changes nothing that is evaluated (Note [Raising
-- through tail calls] in GHC.WebCore.Transform.ResultRaise, Note [Evaluated
-- arguments] in GHC.WebCore.Transform.ArityRaise): the lazy field of P is
-- undefined in some results and arguments, and never forced.

data P = P Int Int

mk :: Int -> P
mk n = if n > 2 then P n undefined else P n (n * 2)
{-# NOINLINE mk #-}

apply :: (Int -> P) -> Int -> Int
apply f n = case f n of P a _ -> a
{-# NOINLINE apply #-}

feed :: (P -> Int) -> [Int] -> Int
feed g xs = sum [ g (P x undefined) + g (P x (x + 1)) | x <- xs ]
{-# NOINLINE feed #-}

main :: IO ()
main = do
  -- results: one lambda tail-calls mk, one constructs P with an undefined field
  print (sum [ apply (\x -> mk x) n + apply (\x -> P (x + 1) undefined) n | n <- [1 .. 10] ])
  -- arguments: constructed P's with undefined fields; one lambda keeps the box
  print (feed (\(P a _) -> a) [1 .. 10] + feed (\p -> length [p]) [1 .. 10])
