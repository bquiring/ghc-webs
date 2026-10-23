-- Note [Lazy parameters of known functions] in GHC.WebCore.Transform.ArityRaise:
-- look is lazy in its key (unused on []), so worker/wrapper leaves it boxed,
-- but every call passes I# n or the key's case binder: the early run raises
-- the key's web, and the key arrives as an Int#
module Main (main) where

look :: Int -> [(Int, b)] -> Maybe b
look _key [] = Nothing
look key ((x, y) : xys)
  | key == x  = Just y
  | otherwise = look key xys

main :: IO ()
main = do
  let table = [ (i, i * 3) | i <- [1 .. 200 :: Int] ]
  print (sum [ maybe 0 id (look k table) | k <- [1 .. 300 :: Int] ])
