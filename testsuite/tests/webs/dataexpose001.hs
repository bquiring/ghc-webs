-- Note [Exposure reasons] in GHC.WebCore.DataSplit: Shown is exposed by its
-- derived Show instance, Result by the exported function, and Local's
-- classes stay internal
module Main (main, result) where

data Shown = Shown Int Int deriving Show

data Result = Result Int Int

data Local = Local Int Int

result :: Int -> Result
result n = Result n (n + 1)

sumLocal :: [Local] -> Int
sumLocal = foldr (\(Local a b) s -> a + b + s) 0
{-# NOINLINE sumLocal #-}

main :: IO ()
main = do
  print (Shown 1 2)
  let Result a b = result 3
  print (a + b)
  print (sumLocal [Local i (i * 2) | i <- [1 .. 10]])
