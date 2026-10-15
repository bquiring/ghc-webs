-- Chunks of a program (Note [Chunks] in GHC.WebCore.Chunk): Chunk002A and
-- Chunk002B form the chunk (chunk002.modules), Main is compiled on its own
-- against their interfaces and linked with the chunk's object.  Main
-- matches on Chunk002A's constructors and uses its instance.
module Main (main) where
import Chunk002A
import Chunk002B (total, twiceAll)
main :: IO ()
main = do
  let ss = mapShapes (scale 2) [Circle 1, Rect 2 3]
  print ss
  print (total ss, [ r | Circle r <- ss ])
  print (twiceAll [1, 2, 3])
  putStrLn (label (Cfg "cfg"))
