{-# LANGUAGE ExistentialQuantification #-}
-- Stream fusion's encoding, with an existential state: a pipeline of
-- combinators that GHC does not inline (as across modules, or when a
-- pipeline is too big to fuse), so each stage's step function is stored in a
-- Stream and called through it.  Data splitting leaves existentials alone
-- (dsedge007); stream002 is the same pipeline with the state in the type.
module Main (main) where

import System.Environment (getArgs)

data Step s a = Done | Skip s | Yield a s

data Stream a = forall s. Stream (s -> Step s a) s

enumFromToS :: Int -> Int -> Stream Int
enumFromToS lo hi = Stream next lo
  where next i | i > hi    = Done
               | otherwise = Yield i (i + 1)
{-# NOINLINE enumFromToS #-}

mapS :: (a -> b) -> Stream a -> Stream b
mapS f (Stream next s0) = Stream next' s0
  where next' s = case next s of
          Done       -> Done
          Skip s'    -> Skip s'
          Yield x s' -> Yield (f x) s'
{-# NOINLINE mapS #-}

filterS :: (a -> Bool) -> Stream a -> Stream a
filterS p (Stream next s0) = Stream next' s0
  where next' s = case next s of
          Done                   -> Done
          Skip s'                -> Skip s'
          Yield x s' | p x       -> Yield x s'
                     | otherwise -> Skip s'
{-# NOINLINE filterS #-}

zipS :: Stream a -> Stream b -> Stream (a, b)
zipS (Stream na sa0) (Stream nb sb0) = Stream next (sa0, sb0, Nothing)
  where next (sa, sb, Nothing) = case na sa of
          Done        -> Done
          Skip sa'    -> Skip (sa', sb, Nothing)
          Yield a sa' -> Skip (sa', sb, Just a)
        next (sa, sb, Just a) = case nb sb of
          Done        -> Done
          Skip sb'    -> Skip (sa, sb', Just a)
          Yield b sb' -> Yield (a, b) (sa, sb', Nothing)
{-# NOINLINE zipS #-}

foldlS' :: (b -> a -> b) -> b -> Stream a -> b
foldlS' f z0 (Stream next s0) = go z0 s0
  where go z s = z `seq` case next s of
          Done       -> z
          Skip s'    -> go z s'
          Yield x s' -> go (f z x) s'
{-# NOINLINE foldlS' #-}

pipeline :: Int -> Int
pipeline n =
  foldlS' (+) 0
    (mapS (\(a, b) -> a * b `mod` 1000003)
      (zipS (filterS even (enumFromToS 1 n)) (mapS (* 3) (enumFromToS 1 n))))

main :: IO ()
main = do
  args <- getArgs
  let n = case args of { [a] -> read a; _ -> 100000 }
  print (pipeline n)
