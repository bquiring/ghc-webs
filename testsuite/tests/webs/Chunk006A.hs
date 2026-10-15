-- The newtypes of chunk006: defined in one chunk module, split in another
module Chunk006A (E (..), U (..), runU, retU, bindU, tick) where

newtype E a = E (Either String a)

newtype U a = U (Int -> E (a, Int))

runU :: U a -> Int -> E (a, Int)
runU (U f) = f

retU :: a -> U a
retU x = U (\s -> E (Right (x, s)))
{-# NOINLINE retU #-}

bindU :: U a -> (a -> U b) -> U b
bindU m k = U (\s -> case runU m s of
                       E (Right (x, s')) -> runU (k x) s'
                       E (Left e)        -> error e)
{-# NOINLINE bindU #-}

tick :: U Int
tick = U (\s -> E (Right (s, s + 1)))
{-# NOINLINE tick #-}
