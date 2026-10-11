-- A local function with a stable unfolding (INLINE) whose unfolding is the
-- only thing that mentions a field: its right-hand side has been
-- simplified, the unfolding has not.  When the field is unboxed, its
-- variable must stay bound (JuicyPixels' Codec.Picture.Gif: vector's
-- step1 and a stream's size; Note [Dead fields] in GHC.WebCore.DataFlatten).
module Main (main) where

data P = P Int Int

mk :: Int -> P
mk k = P (k * 3) (k + 1)
{-# NOINLINE mk #-}

use :: P -> Int -> Int
use p x = case p of
  P n m ->
    let g :: Int -> Int
        g i = ignore i n + m
        {-# INLINE g #-}
    in twice g x
{-# NOINLINE use #-}

-- The rule rewrites ignore in g's right-hand side; stable unfoldings are
-- simplified as in the initial phase, where the rule is not active yet, so
-- g's unfolding keeps the call and its mention of n
ignore :: Int -> Int -> Int
ignore a _ = a
{-# NOINLINE ignore #-}
{-# RULES "ignore" [1] forall a b. ignore a b = a #-}

twice :: (Int -> Int) -> Int -> Int
twice f x = f x * f (x + 1)
{-# NOINLINE twice #-}

main :: IO ()
main = print (sum [ use (mk k) k | k <- [1 .. 1000] ])
