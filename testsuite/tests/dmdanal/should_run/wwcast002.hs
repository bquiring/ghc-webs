-- Higher-order worker/wrapper through a newtype, laziness: the function
-- behind the newtype is lazy in its first argument on one path (undefined at
-- the call), and, with -fpedantic-bottoms, g n diverges before returning
-- when n < 0, so seq (g (-1)) () must diverge.  The partial applications are
-- shared, so g is split (rather than eta-expanded).
module Main (main) where
import Control.Exception

newtype F = F (Int -> Int -> Int)

app :: F -> Int -> Int -> Int
app (F f) = f

g :: Int -> F
g n | n < 0     = error "wwcast002: diverged"
    | otherwise = let k = sum [1 .. n]
                  in F (\x _y -> if k > 100 then x * k else k + 1)    -- x lazy, y dead

main :: IO ()
main = do
  r <- try (evaluate (g (-1) `seq` ()))
  print (either (\(ErrorCall _) -> True) (const False) r)
  let h1 = g 5
      h2 = g 20
  print (app h1 undefined 0, app h1 1 1, app h2 3 undefined, app h2 2 2, app (g 30) 2 2)
