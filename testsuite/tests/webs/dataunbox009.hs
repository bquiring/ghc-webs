{-# LANGUAGE TypeFamilies #-}
-- A local list of pairs, both specialised (Note [Specialising split
-- types]), whose element type is a type family application: the coercion
-- between the producer's and the consumer's list types selects into the
-- pair by the list pattern's positions (GHC.Cmm.CommonBlockElim's
-- Key (ListMap ...) = [Label], building GHC with webs)
module Main (main) where

type family Key m
type instance Key (ListMap m) = [Key m]
type instance Key IntMap = Int

data ListMap m = ListMap
data IntMap = IntMap

mk :: Int -> Int -> [(Key (ListMap IntMap), Int)]
mk a b = if a > b then [] else ([a, a + 1], a * a) : mk (a + 1) b
{-# NOINLINE mk #-}

sumP :: [([Int], Int)] -> Int
sumP []             = 0
sumP ((k, y) : r)   = sum k + y + sumP r
{-# NOINLINE sumP #-}

main :: IO ()
main = print (sumP (mk 1 1000))
