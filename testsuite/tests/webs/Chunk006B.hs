module Chunk006B (run) where

import Chunk006A

loop :: Int -> U Int
loop 0 = retU 0
loop n = tick `bindU` \a -> loop (n - 1) `bindU` \b -> retU (a + b)

run :: Int -> String
run n = case runU (loop n) 0 of
  E (Right (r, s)) -> show (r, s)
  E (Left e)       -> e
