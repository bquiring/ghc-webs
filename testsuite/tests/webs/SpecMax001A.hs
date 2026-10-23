-- Note [Bounded aggressive specialisation] in GHC.Core.Opt.Specialise:
-- total is small and called at five types, spread is larger and called at two
module SpecMax001A (total, spread) where

-- small: specialised under any size bound the test sets
total :: Num a => a -> [a] -> a
total acc []     = acc
total acc (x:xs) = total (acc + x) xs

-- larger than the size bound
spread :: (Ord a, Num a) => [a] -> (a, a, a)
spread = go 0 0 0
  where
    go lo hi s []     = (lo, hi, s)
    go lo hi s (x:xs)
      | x < lo    = go x hi (s + x * 2 - lo) xs
      | x > hi    = go lo x (s + x * 3 - hi) xs
      | x == lo   = go lo hi (s + 1) xs
      | x == hi   = go lo hi (s - 1) xs
      | otherwise = go lo hi (s + x - lo * hi + 7) xs
