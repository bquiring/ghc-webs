-- The importer's LP is the original's constructor, not the copy's
module Main (main) where

import InstCopy002A

findP :: Int -> [LPath a] -> [LNode a]
findP _ []                                  = []
findP v (LP [] : ps)                        = findP v ps
findP v (LP (p@((w, _) : _)) : ps) | v == w = p
                                   | otherwise = findP v ps

main :: IO ()
main = do
  print (length (findP 3 [mk 2 'a', LP [], mk 3 'b']))
  print (mk 2 'a' == mk 2 'b', compare (mk 2 'a') (mk 1 'a'), mk 2 'x')
