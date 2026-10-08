-- Type and data families: family applications are not split; a list behind
-- a type family instance and inside a data family instance.
{-# LANGUAGE TypeFamilies #-}
module Main (main) where

type family Elem c
type instance Elem [e] = e

data family Box a
data instance Box Int = IntBox [(Int, Int)]
newtype instance Box Bool = BoolBox [Bool]

firstElem :: [e] -> Elem [e]
firstElem (x : _) = x
firstElem []      = error "empty"
{-# NOINLINE firstElem #-}

sumBox :: Box Int -> Int
sumBox (IntBox ps) = sum [ a * b | (a, b) <- ps ]
{-# NOINLINE sumBox #-}

countTrue :: Box Bool -> Int
countTrue (BoolBox bs) = length (filter id bs)
{-# NOINLINE countTrue #-}

main :: IO ()
main = do
  print (firstElem [(3 :: Int, 4 :: Int), (5, 6)])
  print (sumBox (IntBox [ (i, i) | i <- [1 .. 10] ]))
  print (countTrue (BoolBox (map even [1 .. 21 :: Int])))
