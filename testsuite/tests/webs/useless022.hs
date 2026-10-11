{-# LANGUAGE MagicHash, UnboxedTuples, BangPatterns #-}
-- runRW# in a tail whose result is masked (after http2's
-- Network.HTTP2.H2.Receiver.getOddStream, where Short.toShort builds the
-- message of an exception thrown when a check fails).  A byte array built
-- under runRW# is put in a strict field, so the simplifier moves the rest of
-- the IO action, which throws or jumps to a join point, into runRW#'s
-- argument.  The action's () result is never used: useless elimination
-- drops it from the join point and must drop it in runRW#'s argument too,
-- keeping runRW# in tail position (Note [runRW# in a masked tail] in
-- GHC.WebCore.Transform.Useless).
module Main (main) where

import Control.Exception
import Control.Monad
import Data.IORef
import GHC.Exts
import GHC.IO (IO(..))

data Msg = Msg ByteArray#

msgLen :: Msg -> Int
msgLen (Msg ba) = I# (sizeofByteArray# ba)

mkMsg :: Int -> Msg
mkMsg (I# n) = runRW# (\s -> case newByteArray# n s of
                          (# s1, mba #) -> case unsafeFreezeByteArray# mba s1 of
                            (# _, ba #) -> Msg ba)
{-# INLINE mkMsg #-}

data Bad = Bad !Int !Msg
instance Show Bad where show (Bad n m) = "Bad " ++ show n ++ " " ++ show (msgLen m)
instance Exception Bad

check :: IORef Int -> Int -> IO ()
check ref n = do
  when (n `mod` 5 == 3) $ do
    let !msg = mkMsg (n + 8)
    throwIO (Bad n msg)
  modifyIORef' ref (+ n)
  when (n > 1000) $ writeIORef ref 0
{-# NOINLINE check #-}

-- check's () result is never read: only this loop calls it.  No n it
-- sees fails the check.
loop :: IORef Int -> [Int] -> IO ()
loop _ [] = return ()
loop ref (n : ns) = check ref n >> loop ref ns

main :: IO ()
main = do
  ref <- newIORef 0
  loop ref [ n | n <- [1 .. 40], n `mod` 5 /= 3 ]
  readIORef ref >>= print
  r <- try (check ref 13 >> return ())
  case r of
    Left (Bad k m) -> print (k, msgLen m)
    Right () -> putStrLn "no error"
