{-# OPTIONS_GHC -funbox-strict-fields #-}
-- Note [Copies of unpacked fields] in GHC.WebCore.DataSplit: Range and Pos
-- (koka's Common.Range in miniature) have unpacked fields, so wrappers;
-- their copies take the workers' fields
module Main (main) where

import Control.Exception ( ErrorCall, evaluate, try )

data Pos = Pos !Int {-# UNPACK #-} !Int

data Range = Range !Pos !Pos Bool

mkRange :: Int -> Range
mkRange i = Range (Pos i (i * 2)) (Pos (i + 3) 0) (even i)
{-# NOINLINE mkRange #-}

width :: Range -> Int
width (Range (Pos a c) (Pos b _) h) = if h then b - a else b - a + c
{-# NOINLINE width #-}

main :: IO ()
main = do
  print (sum (map (width . mkRange) [1 .. 100]))
  -- the copy's fields are as strict as the original's
  r <- try (evaluate (width (Range (Pos 1 2) (error "end") True)))
  putStrLn (either (\e -> "strict: " ++ show (e :: ErrorCall)) show r)
