-- Higher-order worker/wrapper (-fworker-wrapper-function-results).
-- The partial applications escape (stored in a list, and forced with seq)
-- rather than only being called; the result must be the same.
g :: Int -> (Int -> Int -> Int)
g n = let k = sum [1 .. n]
          f x y = x * x + k * x + 7      -- y dead
      in f

main :: IO ()
main = do
  let hs = map g [1 .. 5]
  mapM_ (\h -> h `seq` return ()) hs
  print (sum [ h a b | h <- hs, (a, b) <- [(1, 2), (3, 4)] ])
