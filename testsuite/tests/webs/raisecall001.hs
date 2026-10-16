module Main (main) where

-- Note [Raising through tail calls] in GHC.WebCore.Transform.ResultRaise,
-- Note [Evaluated arguments] in GHC.WebCore.Transform.ArityRaise: nofib's
-- integrate.  The D# integrate1D builds moves to the lambda that
-- tail-calls it, and from the lambdas to the calls of f; the D#s the calls
-- pass move into the lambdas.

integrate1D :: Double -> Double -> (Double -> Double) -> Double
integrate1D l u f =
  let d = (u - l) / 8.0 in
  d * sum [ f l * 0.5, f (l + d), f (l + 2.0 * d), f (l + 3.0 * d), f (l + 4.0 * d)
          , f (u - 3.0 * d), f (u - 2.0 * d), f (u - d), f u * 0.5 ]
{-# NOINLINE integrate1D #-}

integrate2D :: Double -> Double -> Double -> Double -> (Double -> Double -> Double) -> Double
integrate2D l1 u1 l2 u2 f = integrate1D l2 u2 (\y -> integrate1D l1 u1 (\x -> f x y))

zark :: Double -> Double -> Double
zark u v = integrate2D 0.0 u 0.0 v (\x y -> x * y)

main :: IO ()
main = print (sum [ zark u (2 * u) | u <- [1 .. 200] ])
