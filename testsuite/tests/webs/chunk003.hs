-- A library built as a chunk (Note [Chunks] in GHC.WebCore.Chunk):
-- chunk003lib/ compiled with --make -fcore-webs-chunk -no-link, as Cabal
-- would; then Main compiled on its own against its interfaces and linked
-- with all of its objects (the first holds the chunk, the others are empty).
module Main (main) where
import Chunk003A
import Chunk003B
main :: IO ()
main = do
  let ss = mapShapes (scale 2) [Circle 1, Rect 2 3]
  print ss
  print (total ss, [ r | Circle r <- ss ])
  print (twiceAll [1, 2, 3])
