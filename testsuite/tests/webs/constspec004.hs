-- Note [Specialising on lambdas]: nested lambdas passed to a recursive
-- function are lambda-lifted; a lifted function that ends up in no key is
-- put back, and putting back the outer one brings the inner one's free
-- top-level binders (msg) into its body (QuickCheck's
-- Test.QuickCheck.Property: lookupIdSubst panic).  Four other keys use up
-- mapRose's budget first, so the nested lambdas are put back.
module Main (main) where

data Rose a = MkRose a [Rose a]

mapRose :: (a -> b) -> Rose a -> Rose b
mapRose f (MkRose x rs) = MkRose (f x) [ mapRose f r | r <- rs ]

msg :: String
msg = "too big"
{-# NOINLINE msg #-}

sizeR :: Rose a -> Int
sizeR (MkRose _ rs) = 1 + sum (map sizeR rs)

flatten :: Rose a -> [a]
flatten (MkRose x rs) = x : concatMap flatten rs

tree :: Int -> Rose Int
tree 0 = MkRose 0 []
tree n = MkRose n [tree (n - 1), tree (n `div` 2)]

inc, dbl, neg, sq :: Int -> Int
inc x = x + 1
dbl x = x * 2
neg x = 0 - x
sq x = x * x
{-# NOINLINE inc #-}
{-# NOINLINE dbl #-}
{-# NOINLINE neg #-}
{-# NOINLINE sq #-}

four :: Rose Int -> [Int]
four t = map (sum . flatten) [mapRose inc t, mapRose dbl t, mapRose neg t, mapRose sq t]

combine :: Int -> Rose Int -> Rose (Rose String)
combine k t = mapRose (\x -> mapRose (\y -> if x + y + k > 9 then msg else show y) t) t

main :: IO ()
main = do
  let t = tree 4
  print (four t)
  let c = combine 3 t
  print (sizeR c, take 6 (concatMap flatten (flatten c)))
