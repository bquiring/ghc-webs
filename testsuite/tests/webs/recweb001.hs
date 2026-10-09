-- A recursive type whose function field's web takes the type itself:
-- T = (Int, T ->{w} Int).  Every lambda of w takes its T apart at once and
-- is called through the field (unknown calls), so raising w's argument would
-- give (Int, T ->{w} Int), whose second component is w again: unboxing it
-- must stop, not unfold T forever.
module Main (main) where

data T = T Int (T -> Int)

fun :: T -> Int
fun (T a g)
  | a <= 0    = a
  | otherwise = a + g (T (a - 1) fun)
{-# NOINLINE fun #-}

alt :: T -> Int
alt (T a g)
  | a <= 0    = 1
  | otherwise = 2 * a + g (T (a - 1) alt)
{-# NOINLINE alt #-}

-- a third lambda of the web, local, with a free variable
scaled :: Int -> T -> Int
scaled k = \(T a g) -> if a <= 0 then k else k * a + g (T (a - 1) fun)
{-# NOINLINE scaled #-}

main :: IO ()
main = do
  print (fun (T 10 alt), alt (T 10 fun))
  print (scaled 3 (T 6 (scaled 2)))
  print (fun (T 0 alt) + alt (T 4 (scaled 5)) + scaled 7 (T 9 fun))
