-- Functions stored in data structures and newtypes.  Data constructor
-- fields and newtype axioms have exposed signatures, so these webs are
-- exposed.
module Main (main) where

newtype Endo = Endo (Int -> Int)

appEndo :: Endo -> Int -> Int
appEndo (Endo f) x = f x
{-# NOINLINE appEndo #-}

data Box = Box (Int -> Int) Int

runBox :: Box -> Int
runBox (Box f x) = f x
{-# NOINLINE runBox #-}

compose :: [Int -> Int] -> Int -> Int
compose fs x = foldr (\f acc -> f acc) x fs
{-# NOINLINE compose #-}

main :: IO ()
main = do
  print (appEndo (Endo (+ 3)) 4)
  print (runBox (Box (* 5) 6))
  print (compose [(+ 1), (* 2), subtract 3] 10)
  print (map (\x -> x * x) [1, 2, 3 :: Int])
