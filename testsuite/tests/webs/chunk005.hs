-- A chunk with a module that has an hs-boot file (Note [Chunks] in
-- GHC.WebCore.Chunk)
import Chunk005A
import Chunk005B
main :: IO ()
main = print (sizes (map mk [1..15]))
