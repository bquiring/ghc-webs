module Main (main) where

-- Note [Constant specialisation] in GHC.WebCore.Transform.ConstSpec: a
-- chain.  outer passes its static parameter on to inner, which is
-- recursive with it static too; only once outer has a copy for step does
-- that copy pass a known function to inner (-fcore-webs-spec-calls, a
-- second round).  Also: a call that passes a known function for only one
-- of two static parameters, a partial application, and a static parameter
-- that is stored as well as called.

inner :: (Int -> Int) -> Int -> Int -> Int
inner f acc 0 = acc
inner f acc n = inner f (f acc + n) (n - 1)
{-# NOINLINE inner #-}

outer :: (Int -> Int) -> [Int] -> [Int]
outer f []       = []
outer f (x : xs) = inner f (f x) x : outer f xs
{-# NOINLINE outer #-}

step :: Int -> Int
step x = x * 3 `mod` 1000003
{-# NOINLINE step #-}

twice :: Int -> Int
twice x = x * 2 `mod` 1000033
{-# NOINLINE twice #-}

both :: (Int -> Int) -> (Int -> Int) -> Int -> [Int -> Int]
both f g 0 = [f, g]
both f g n = f n `seq` g n `seq` both f g (n - 1)
{-# NOINLINE both #-}

main :: IO ()
main = do
  print (sum (outer step [1 .. 2000]))
  let h = (+ 1) . length . show
  print (map ($ 5) (both step h 100))
  let p = inner twice 1
  print (map p [10, 20])
