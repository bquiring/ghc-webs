-- The library part of a larger example for higher-order worker/wrapper
-- (-fworker-wrapper-function-results): numerics.  Cases marked [+] should be
-- split, [-] should not (the reason is given).
module WWLarge2A (applyN, experiment, mkIntegrator, mkPoly, scaleAll, simulate) where


import Data.List (foldl')

------------------------------------------------------------------------
-- [+ result] mkIntegrator precomputes Simpson weights (work), then returns
-- an integrator whose tolerance argument is dead.  The partial application
-- is shared by a loop.
mkIntegrator :: Int -> ((Double -> Double) -> Double -> Double -> Double -> Double)
mkIntegrator n =
  let ws = [ if i == 0 || i == n then 1 else if odd i then 4 else 2 | i <- [0 .. n] ]
  in \f a b _tol -> let h = (b - a) / fromIntegral n
                    in h / 3 * sum [ w * f (a + fromIntegral i * h) | (i, w) <- zip [0 :: Int ..] ws ]

------------------------------------------------------------------------
-- [+ argument] simulate gives the observer its local force law, whose
-- third argument (a time stamp) is dead.
simulate :: ((Double -> Double -> Double -> Double) -> Double) -> Double -> Double
simulate observe k =
  let damping = sqrt (k * 2 + 1)
      force x v _t = negate (k * x) - damping * v + sin x * 0.01
  in observe force + force 1 0 0

------------------------------------------------------------------------
-- [+ argument, nested] experiment gives its driver a function that is
-- itself given the local force law.
experiment :: ((((Double -> Double -> Double -> Double) -> Double) -> Double) -> Double) -> Double -> Double
experiment drive k =
  let damping = k / 3 + 0.5
      force x v _t = negate (k * x) - damping * v + cos v * 0.02
  in drive (\use -> use force + use force) + force 0.5 0.5 0

------------------------------------------------------------------------
-- [- result] the partial application is used just once, with all the
-- arguments: GHC eta-expands mkPoly instead.
mkPoly :: Double -> (Double -> Double -> Double)
mkPoly c = let c2 = c * c + 1 in \x _unused -> c2 * x * x + c * x + 1

------------------------------------------------------------------------
-- [- result] polymorphic: worker/wrapper keeps it, but the function-argument
-- split does not handle type parameters (yet).
applyN :: Num a => ((a -> a -> a) -> a) -> a -> a
applyN k s = let step a _b = a * s + 1 in k step + step s s

------------------------------------------------------------------------
-- [- noinline] a NOINLINE function's wrapper could not be inlined.
scaleAll :: ((Double -> Double -> Double) -> Double) -> Double -> Double
scaleAll k s = let sc x _ = x * s + s * s in k sc + sc 1 1
{-# NOINLINE scaleAll #-}

