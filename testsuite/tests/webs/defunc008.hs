-- The specialised type has more parameters than the original two: every use
-- of the web's type is  D (t1, t2) t3, so it becomes  D' t1 t2 t3, and a
-- constructor has three equalities where the old one had two
-- (spectral/circsim, spectral/hartel/solid).
module Main (main) where

onPair :: ((a, b) -> c) -> (a, b) -> c
onPair f p = f p
{-# NOINLINE onPair #-}

main :: IO ()
main = do
  print (onPair (\p -> fst p + snd p) (1 :: Int, 2 :: Int))
  putStrLn (onPair (\(s, t) -> s ++ t) ("a", "b"))
