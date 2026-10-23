module SatLint where

-- Two static value arguments (c, d) and a static dictionary: SAT fires.
scale :: Num a => a -> a -> [a] -> [a]
scale c d []     = []
scale c d (x:xs) = (x * c + d) : scale c d xs
{-# NOINLINE scale #-}
