module SplitClass001A (Shape(..), Box(..), Circle(..), total) where

-- A class of the program's own: its dictionaries reach only the program's
-- functions, so with -fcore-webs-split-classes it is split, and its
-- methods' webs are internal (useless elimination drops scale's unused
-- pair, arity raising passes area's pair as two arguments)
class Shape a where
  area  :: a -> (Int, Int) -> Int
  scale :: a -> (Int, Int) -> Int -> a
  label :: a -> String

data Box = Box Int Int
data Circle = Circle Int

instance Shape Box where
  area (Box w h) (dx, dy) = (w + dx) * (h + dy)
  scale (Box w h) _ k = Box (w * k) (h * k)
  label _ = "box"

instance Shape Circle where
  area (Circle r) (dx, _) = 3 * (r + dx) * (r + dx)
  scale (Circle r) _ k = Circle (r * k)
  label _ = "circle"

-- Not specialised (-fno-specialise): the dictionary survives to the early run
total :: Shape a => [a] -> (Int, String)
total xs = go 0 "" xs
  where
    go acc l []       = (acc, l)
    go acc l (x : ys) = let y = scale x (acc, acc) 2
                        in go (acc + area y (1, acc `mod` 7)) (label y) ys
{-# NOINLINE total #-}
