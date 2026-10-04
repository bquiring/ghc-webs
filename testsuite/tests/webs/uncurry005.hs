-- Laziness: forcing a partial application.  pick undefined diverges when
-- forced, because pick does a case before returning the inner lambda.
-- Uncurrying would eta-expand the partial application into a lambda, which
-- does not diverge, so the web must be rejected.  (-fpedantic-bottoms stops
-- GHC's own eta-expansion from doing the same.)
module Main (main) where

import Control.Exception

force2 :: (Bool -> Int -> Int) -> Bool -> ()
force2 f c = f c `seq` ()
{-# NOINLINE force2 #-}

pick :: Bool -> Int -> Int
pick c = case c of
  True  -> \b -> b + 1
  False -> \b -> b * 2
{-# NOINLINE pick #-}

main :: IO ()
main = do
  r <- try (evaluate (force2 pick undefined))
  putStrLn (either (\(ErrorCall _) -> "exception") show r)
  print (force2 pick True)
