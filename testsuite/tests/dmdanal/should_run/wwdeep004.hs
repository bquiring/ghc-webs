-- Higher-order worker/wrapper with -fpedantic-bottoms: a partial
-- application at level 2 diverges before returning its function, so
-- seq (g n a) () must diverge; each level's wrapper uses a case.  (Without
-- -fpedantic-bottoms, plain GHC itself eta-expands g and this prints False:
-- the same trade the default wrapper makes; see (LetOrCase).)
module Main (main) where
import Control.Exception

g :: Int -> (Int -> (Int -> Int -> Int))
g n = let k1 = sum [1 .. n]
      in \a -> if a < 0 then error "wwdeep004: diverged"
               else let k2 = k1 * a
                    in \x y -> x * k2 + x * x * k1 + 1      -- y dead
{-# NOINLINE run #-}

run :: Int -> Int -> Int
run n a = let h = g n a in h 3 0 + h 4 0

main :: IO ()
main = do
  r <- try (evaluate (g 10 (-1) `seq` ()))
  print (either (\(ErrorCall _) -> True) (const False) r)
  print (run 10 2, run 5 3)
