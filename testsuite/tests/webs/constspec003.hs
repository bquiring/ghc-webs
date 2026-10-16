module Main (main) where

-- Note [Specialising on lambdas] in GHC.WebCore.Transform.ConstSpec
-- (-fcore-webs-spec-lambdas): keys that are partial applications and
-- lambdas, and non-recursive candidates.
--
--  * integ (not recursive, calls f three times) is passed nested lambdas
--    with free variables, as in nofib imaginary/integrate: both are lifted
--    and keys;
--  * search (recursive, f static) is passed a partial application of a
--    known function to a local, as in nofib spectral/ida;
--  * loop (not recursive, calls f once, in a local loop);
--  * once (not recursive, calls f once, not in a loop) is no candidate;
--  * a lambda that calls a free variable is not lifted;
--  * more lambdas than keys: the fifth is put back;
--  * a polymorphic lambda, with a free type variable;
--  * a lambda over a case binder, whose OtherCon unfolding must not go
--    with it to the lifted function's lambda binder (nofib real/gg).

integ :: Double -> Double -> (Double -> Double) -> Double
integ l u f = let h = (u - l) / 2 in h * (f l + 2 * f (l + h) + f u)
{-# NOINLINE integ #-}

search :: (Int -> Bool) -> Int -> [Int] -> Int
search f acc []       = acc
search f acc (x : xs) | f x       = search f (acc + x) xs
                      | otherwise = search f acc xs
{-# NOINLINE search #-}

below :: Int -> Int -> Bool
below cut x = x < cut
{-# NOINLINE below #-}

loop :: (Int -> Int) -> Int -> Int
loop f n = go 0 n
  where go acc 0 = acc
        go acc k = go (f acc + k) (k - 1)
{-# NOINLINE loop #-}

once :: (Int -> Int) -> Int -> Int
once f n = f n + n
{-# NOINLINE once #-}

filt :: (Int -> Bool) -> [Int] -> [Int]
filt _ [] = []
filt f (x : xs) | f x       = x : filt f xs
                | otherwise = filt f xs
{-# NOINLINE filt #-}

pick :: [Int] -> [Int] -> [Int]
pick [] = filt (const True)
pick ks = filt (\x -> elem x ks)
{-# NOINLINE pick #-}

app :: (a -> [a]) -> a -> Int -> [a]
app f x 0 = f x
app f x n = app f x (n - 1)
{-# NOINLINE app #-}

main :: IO ()
main = do
  -- nested lambdas with free variables
  let cuts = [3, 50, 700]
  print (sum [ integ 0 y (\x -> integ 0 x (\z -> z * x + y)) | c <- cuts, let y = fromIntegral c ])
  -- a partial application of a known function to a local
  print [ search (below c) 0 [1 .. 1000] | c <- cuts ]
  -- not recursive, called in a loop; five lambdas, four keys
  print [ loop (\a -> a * k `mod` 1009) 100 + loop (\a -> a + k) 10
          + loop (\a -> a - k) 20 + loop (\a -> a `div` 2 + k) 30
          + loop (\a -> a * 3 - k) 40 | k <- [1, 2] ]
  print (once (\a -> a * 7) 6)
  -- a lambda that calls a free variable
  let g = if length cuts > 2 then (* 2) else (+ 2)
  print (loop (\a -> g a + 1) 10)
  -- a polymorphic lambda
  print (app (\v -> [v, v]) 'x' 3, app (\v -> replicate 3 v) True 2)
  -- a lambda over a case binder
  print (pick cuts [1 .. 1000], length (pick [] [1 .. 10]))
