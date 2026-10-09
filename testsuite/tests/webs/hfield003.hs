-- Note [Hidden fields] in GHC.WebCore.Sigs: a type that an unsafe coercion
-- relates to another keeps its fields exposed.  H's field web would be
-- raised (curried components), but H is coerced to H', which still reads
-- the pair: without the rule, use' got garbage.
module Main (main, H'(..)) where

import Unsafe.Coerce (unsafeCoerce)

data H  = H  Int ((Int, Int) -> Int)
data H' = H' Int ((Int, Int) -> Int)

f1, f2 :: (Int, Int) -> Int
f1 (a, b) = a + b
{-# NOINLINE f1 #-}
f2 (a, b) = a * b
{-# NOINLINE f2 #-}

use :: H -> Int
use (H n g) = g (n, n + 1)
{-# NOINLINE use #-}

use' :: H' -> Int
use' (H' n g) = g (n, 10)
{-# NOINLINE use' #-}

conv :: H -> H'
conv = unsafeCoerce
{-# NOINLINE conv #-}

main :: IO ()
main = do
  print (use (H 3 f1) + use (H 4 f2))
  print (use' (conv (H 5 f1)), use' (conv (H 6 f2)))
