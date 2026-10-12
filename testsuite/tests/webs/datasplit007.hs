-- atomicModifyIORef's function returns a pair; the RTS (atomicModifyMutVar2#)
-- takes the new contents out of its first field with a selector thunk, and
-- no case in the program reads that field.  Splitting the pair let
-- dead-field elimination drop it, and the IORef got the second field
-- (aeson's Data.Aeson.Internal.TH; Note [Non-parametric functions] in
-- GHC.WebCore.DataSplit).
module Main (main) where

import qualified Data.Map as M
import Data.IORef

memo :: IORef (M.Map Int String) -> Int -> IO String
memo ref k = do
  m <- readIORef ref
  case M.lookup k m of
    Just s -> return s
    Nothing -> do
      let s = show (k * k)
      atomicModifyIORef ref (\m' -> (M.insert k s m', ()))
      return s
{-# NOINLINE memo #-}

main :: IO ()
main = do
  ref <- newIORef M.empty
  xs <- mapM (memo ref) ([1 .. 20] ++ [5 .. 25])
  print (length (concat xs))
  m <- readIORef ref
  print (M.size m, M.lookup 7 m)
