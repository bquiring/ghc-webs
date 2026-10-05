-- Library part of wwcompose002: h returns a function with a dead argument,
-- and is split; its wrapper reaches wwcompose002 through the interface.
module WWComposeA (h) where

h :: Int -> (Int -> Int -> Int)
h m = let k = sum [1 .. m]
      in \x _y -> (x * 1 + k) * (x - 1) + (x * 2 + k) * (x - 2) + (x * 3 + k) * (x - 3) + (x * 4 + k) * (x - 4) + (x * 5 + k) * (x - 5) + (x * 6 + k) * (x - 6) + (x * 7 + k) * (x - 7) + (x * 8 + k) * (x - 8) + (x * 9 + k) * (x - 9) + (x * 10 + k) * (x - 10) + (x * 11 + k) * (x - 11) + (x * 12 + k) * (x - 12) + (x * 13 + k) * (x - 13) + (x * 14 + k) * (x - 14) + (x * 15 + k) * (x - 15) + (x * 16 + k) * (x - 16) + (x * 17 + k) * (x - 17) + (x * 18 + k) * (x - 18) + (x * 19 + k) * (x - 19)      -- y dead
