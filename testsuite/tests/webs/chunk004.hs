-- The chunk's SPECIALISE rule fires in an importer (Note [Interfaces of a
-- chunk] in GHC.WebCore.Chunk)
import Chunk004A
import Chunk004B

main :: IO ()
main = do
  let xs = [ i - 50 | i <- [1 .. 100 :: Int] ]
  print (total xs)
  print (sumT [ T i (i - 3) | i <- [1 .. 10] ])
