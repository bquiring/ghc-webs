-- Note [Useless elimination]: a web that appears in the type of a
-- coercion variable (bound by matching UnsafeRefl, from unsafeIOToST's
-- unsafeCoerce) keeps its result components: the variable's occurrences in
-- coercions would keep the old type.  From hashable's XXH3 (Web Lint:
-- "Mismatch in type between binder and occurrence").
module Main (main) where

import Control.Monad.ST
import Control.Monad.ST.Unsafe (unsafeIOToST)
import Data.IORef

newtype State s = State (IORef Int)

reset :: State s -> Int -> ST s ()
reset (State r) n = unsafeIOToST (writeIORef r n)
{-# NOINLINE reset #-}

bump :: State s -> ST s ()
bump (State r) = unsafeIOToST (modifyIORef' r (+ 1))
{-# NOINLINE bump #-}

run :: IORef Int -> IO ()
run r = stToIO (reset (State r) 5 >> bump (State r) >> bump (State r))

main :: IO ()
main = do
  r <- newIORef 0
  run r
  readIORef r >>= print
