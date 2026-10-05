-- Higher-order worker/wrapper (-fworker-wrapper-function-results).
-- Laziness: on one path the returned function does not use x, which is
-- undefined at the call; the split must not unbox x (it is not strict), or
-- the call would diverge.  y is dead and may be dropped.
g :: Int -> (Int -> Int -> Int)
g n = let k = sum [1 .. n]
      in if n > 5 then \x y -> x * k + 1      -- y dead, x strict here
                  else \x y -> k + 2          -- x and y dead here
{-# NOINLINE g #-}

main :: IO ()
main = do
  let h = g 3
  print (h undefined undefined + h 4 5)
  let h' = g 10
  print (h' 2 undefined)
