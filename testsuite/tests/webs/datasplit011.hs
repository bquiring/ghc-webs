-- A newtype class kept only through a newtype child (Note [Keeping only
-- useful splits] in GHC.WebCore.DataSplit): U's representation holds E,
-- whose Either is only ever built with Right (Left is dropped: a useful
-- split).  E's class is kept for its Either; U's must be kept too, or U goes
-- back to the original, whose axiom names the original E, while the E
-- inside stays split -- an ill-typed coercion (futhark's
-- Language.Futhark.TypeChecker.Unify, a local UnifyM over StateT and
-- ExceptT).
module Main (main) where

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

loop :: Int -> U Int
loop 0 = retU 0
loop n = tick `bindU` \a -> loop (n - 1) `bindU` \b -> retU (a + b)

main :: IO ()
main = case runU (loop 100) 0 of
  E (Right (r, s)) -> print (r, s)
  E (Left e)       -> putStrLn e
