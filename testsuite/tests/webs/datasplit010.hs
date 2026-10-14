-- Data splitting zaps vanilla unfoldings, and worker/wrapper runs before
-- the simplifier rebuilds them: small functions lost their "certainly
-- inlines" stable unfoldings and became worker/wrapper pairs, whose
-- wrappers (active from phase 2, not inlined in boring contexts) made an
-- importing module of GHC's grow 37x.  Note [Restoring vanilla unfoldings]
-- in GHC.WebCore.Pipeline.  The state monad's small methods must get no
-- wrapper: datasplit010_wrappers greps -ddump-simpl for wrappers of them
-- (InlPrag=[2]) and expects none.
module Main (main) where

data Env = Env { envA :: Int, envB :: [Int], envC :: Int }

newtype M a = M { runM :: Env -> Int -> (a, Env, Int) }

instance Functor M where
  fmap f (M m) = M (\e s -> case m e s of (a, e', s') -> (f a, e', s'))
instance Applicative M where
  pure a = M (\e s -> (a, e, s))
  M f <*> M m = M (\e s -> case f e s of
                     (g, e', s') -> case m e' s' of (a, e'', s'') -> (g a, e'', s''))
instance Monad M where
  M m >>= k = M (\e s -> case m e s of (a, e', s') -> runM (k a) e' s')

getA :: M Int
getA = M (\e s -> (envA e, e, s))

getB :: M [Int]
getB = M (\e s -> (envB e, e, s))

tick :: M ()
tick = M (\e s -> ((), e, s + 1))

pushB :: Int -> M ()
pushB x = M (\e s -> ((), e { envB = x : envB e }, s))

-- a local list, which data splitting splits (as in datasplit001)
upto :: Int -> Int -> [Int]
upto a b = if a > b then [] else a : upto (a + 1) b
{-# NOINLINE upto #-}

total :: [Int] -> Int
total []       = 0
total (x : xs) = x + total xs
{-# NOINLINE total #-}

step :: Int -> M Int
step n = do
  a <- getA
  tick
  pushB (a + n)
  bs <- getB
  return (total (upto a n) + length bs)

main :: IO ()
main = do
  let (r, e, s) = runM (mapM step [1 .. 50]) (Env 3 [] 0) 0
  print (sum r, length (envB e), envC e, s)
