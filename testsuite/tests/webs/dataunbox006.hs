-- Note [Strictly eliminated fields].  mk's pairs hold thunks (a + 1, a * a),
-- but every cell is built where it is demanded (mk's result, its tail a
-- thunk) and every match on the list and the pairs is strict in them, so
-- they are strictly eliminated: unboxed, evaluated when the cell is built.
-- bad's pairs hold an error, and count never looks at them: the cells'
-- heads are not strictly eliminated, so nothing may be forced early.
module Main (main) where

mk :: Int -> Int -> [(Int, Int)]
mk a b = if a > b then [] else (a + 1, a * a) : mk (a + 1) b
{-# NOINLINE mk #-}

sumP :: [(Int, Int)] -> Int
sumP []           = 0
sumP ((x, y) : r) = x + y + sumP r
{-# NOINLINE sumP #-}

bad :: Int -> [(Int, Int)]
bad 0 = []
bad n = (error "never", n) : bad (n - 1)
{-# NOINLINE bad #-}

count :: [(Int, Int)] -> Int
count []      = 0
count (_ : r) = 1 + count r
{-# NOINLINE count #-}

main :: IO ()
main = do
  print (sumP (mk 1 1000))
  print (count (bad 10))
