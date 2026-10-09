-- A recursive type whose function field's web returns the type itself:
-- R = (Int, Int ->{w} R).  Every lambda of w builds an R at each return, so
-- raising w's result would give (# Int, Int ->{w} R #), whose second
-- component is w again.
module Main (main) where

data R = R Int (Int -> R)

countdown :: Int -> R
countdown n = R n (\k -> countdown (n - k))
{-# NOINLINE countdown #-}

doubling :: Int -> R
doubling n = R n (\k -> if even k then doubling (n * 2 `mod` 10007) else countdown (n + k))
{-# NOINLINE doubling #-}

-- A type of its own, so its web holds only lambdas that construct the R2
-- they return, whose field is the web again: result raising would return
-- (# Int, Int ->{w} R2 #)
data R2 = R2 Int (Int -> R2)

step :: Int -> Int -> R2
step n = \k -> R2 (n - k) (step (n - k))
{-# NOINLINE step #-}

halve :: Int -> Int -> R2
halve n = \k -> R2 (n `div` 2 + k) (if even k then halve (n + 1) else step n)
{-# NOINLINE halve #-}

walkR2 :: Int -> R2 -> Int
walkR2 0 (R2 a _) = a
walkR2 s (R2 a f) = a + walkR2 (s - 1) (f s)
{-# NOINLINE walkR2 #-}

walkR :: Int -> R -> Int
walkR 0 (R a _) = a
walkR s (R a f) = a + walkR (s - 1) (f s)
{-# NOINLINE walkR #-}

main :: IO ()
main = do
  print (walkR 10 (countdown 100), walkR 12 (doubling 3))
  print (walkR 0 (doubling 0) + walkR 3 (doubling 3) + walkR 6 (doubling 6))
  print (walkR2 8 (R2 50 (step 50)), walkR2 5 (halve 9 1))
