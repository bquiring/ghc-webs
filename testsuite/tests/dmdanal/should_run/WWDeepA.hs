module WWDeepA (g3, g4, g6) where
import Debug.Trace

-- Three levels of returned functions, each doing (traced) work before
-- returning the next; the innermost function has a dead argument y.
g3 :: Int -> (Int -> (Int -> (Int -> Int -> Int)))
g3 n = let k1 = trace "k1" (sum [1 .. n])
       in \a -> let k2 = trace "k2" (k1 * a + 1)
                in \b -> let k3 = trace "k3" (k2 + b)
                         in \x y -> (x * 1 + k3) * (x - 1)
               + (x * 2 + k3) * (x - 2)
               + (x * 3 + k3) * (x - 3)
               + (x * 4 + k3) * (x - 4)
               + (x * 5 + k3) * (x - 5)
               + (x * 6 + k3) * (x - 6)
               + (x * 7 + k3) * (x - 7)
               + (x * 8 + k3) * (x - 8)
               + (x * 9 + k3) * (x - 9)
               + (x * 10 + k3) * (x - 10)
               + (x * 11 + k3) * (x - 11)
               + (x * 12 + k3) * (x - 12)
               + (x * 13 + k3) * (x - 13)
               + (x * 14 + k3) * (x - 14)
               + (x * 15 + k3) * (x - 15)
               + (x * 16 + k3) * (x - 16)
               + (x * 17 + k3) * (x - 17)
               + (x * 18 + k3) * (x - 18)
               + (x * 19 + k3) * (x - 19)
               + (x * 20 + k3) * (x - 20)
               + (x * 21 + k3) * (x - 21) + k1   -- y dead

-- Something to gain at two levels: level 1 has a dead argument d, level 3
-- a dead argument y and a strict argument x.
g4 :: Int -> (Int -> Int -> (Int -> (Int -> Int -> Int)))
g4 n = let k1 = trace "j1" (sum [1 .. n])
       in \a d -> let k2 = trace "j2" (k1 * a + 1)                 -- d dead
                  in \b -> let k3 = trace "j3" (k2 + b)
                           in \x y -> (x * 1 + k3) * (x - 1)
               + (x * 2 + k3) * (x - 2)
               + (x * 3 + k3) * (x - 3)
               + (x * 4 + k3) * (x - 4)
               + (x * 5 + k3) * (x - 5)
               + (x * 6 + k3) * (x - 6)
               + (x * 7 + k3) * (x - 7)
               + (x * 8 + k3) * (x - 8)
               + (x * 9 + k3) * (x - 9)
               + (x * 10 + k3) * (x - 10)
               + (x * 11 + k3) * (x - 11)
               + (x * 12 + k3) * (x - 12)
               + (x * 13 + k3) * (x - 13)
               + (x * 14 + k3) * (x - 14)
               + (x * 15 + k3) * (x - 15)
               + (x * 16 + k3) * (x - 16)
               + (x * 17 + k3) * (x - 17)
               + (x * 18 + k3) * (x - 18)
               + (x * 19 + k3) * (x - 19)
               + (x * 20 + k3) * (x - 20)
               + (x * 21 + k3) * (x - 21)            -- y dead

-- Five levels, each doing work (so GHC cannot eta-expand them): deeper than
-- the split looks (maxFunResultDepth = 4); the dead argument at level 5
-- stays, and the program is unchanged
g6 :: Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int
g6 n = let k1 = sum [1 .. n]
       in \a -> let k2 = sum [k1 .. k1 + a]
                in \b -> let k3 = sum [k2 .. k2 + b]
                         in \c -> let k4 = sum [k3 .. k3 + c]
                                  in \d -> let k5 = sum [k4 .. k4 + d]
                                           in \x y -> (x * 1 + k5) * (x - 1)
               + (x * 2 + k5) * (x - 2)
               + (x * 3 + k5) * (x - 3)
               + (x * 4 + k5) * (x - 4)
               + (x * 5 + k5) * (x - 5)
               + (x * 6 + k5) * (x - 6)
               + (x * 7 + k5) * (x - 7)
               + (x * 8 + k5) * (x - 8)
               + (x * 9 + k5) * (x - 9)
               + (x * 10 + k5) * (x - 10)
               + (x * 11 + k5) * (x - 11)   -- y dead
