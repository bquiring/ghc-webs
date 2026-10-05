{-# LANGUAGE BangPatterns #-}
-- Continuations called with constructed data: (Constructed) in
-- Note [Worker/wrapper for function arguments].  [+] marks functions the
-- split should apply to, [-] functions it must leave alone.
module WWContDump where

import Debug.Trace (trace)

-- [+] Every call of k passes an I# and a pair.  The pair's fields are lazy:
-- some continuations never force them (trace counts, undefined).
step :: Int -> Int -> (Int -> (Int, Int) -> r) -> r
step !a !b k
  | a > b + 100 = k (a + b) (a, b)
  | a > b       = k (a * 3 - b) (b, trace "lazy field (a > b)" (a * a - b))
  | a == b      = k (a * b + 7) (b, a + 1)
  | a < 0       = k (a - b * 2) (undefined, b)
  | otherwise   = k (a - b) (trace "lazy field (a < b)" (a - 1), b * 5 + a)

-- [+] A pair at every call, from a local loop (k is free in go)
findK :: (Int -> Bool) -> [Int] -> ((Int, Int) -> r) -> r
findK p xs0 k = go 0 xs0
  where
    go !i []       = k (i, -1)
    go !i (x : xs) | p x       = k (i, x * 2 + i)
                   | otherwise = go (i + 1) xs

-- [-] Different constructors at different calls of k
pick :: Int -> (Maybe Int -> r) -> r
pick n k | n > 10    = k (Just (n * n + 3 * n - 1))
         | n > 5     = k (Just (n * 7 - 2 * n + 11))
         | otherwise = k Nothing

-- [-] A constructor with strict fields
data SP = SP !Int !Int deriving Show

strictK :: Int -> (SP -> r) -> r
strictK n k | n > 3     = k (SP (n * n + 1) (n - 3))
            | otherwise = k (SP (n + 100) (n * 2 + 5))

-- Unknown continuations, chosen at run time
conts :: [Int -> (Int, Int) -> Int]
conts = [\s (x, _) -> s * x, \s _ -> s, \s p -> s + snd p]
{-# NOINLINE conts #-}

main0 :: IO ()
main0 = do
  print (step 500 3 (\s (x, y) -> s + x + y))
  print (step 9 2 (\s _ -> s))                    -- lazy field never traced
  print (step 9 2 (\s (_, y) -> s + y))           -- traced once
  print (step 4 4 (\s p -> s + fst p + snd p))
  print (step (-5) 1 (\s (_, y) -> s + y))        -- undefined field never forced
  print (step 1 9 (\s (x, y) -> s + x + y))
  mapM_ (\k -> print (step 6 1 k)) conts
  mapM_ (\k -> print (step 0 7 k)) conts
  print (findK even [1, 3, 5, 6, 7] (\(i, v) -> v + i))
  print (findK (> 100) [1, 2, 3] (\(i, v) -> i * v))
  print (findK odd [2, 4, 9] fst)
  print (pick 12 (maybe 0 (+ 1)), pick 7 (maybe 0 (+ 2)), pick 1 (maybe 0 (+ 3)))
  print (strictK 5 (\(SP x y) -> x + y), strictK 2 show)
