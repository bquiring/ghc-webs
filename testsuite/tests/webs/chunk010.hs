module Main (main) where
import Chunk010C
import Chunk010X (xLater)
main :: IO ()
main = print (run 2, xLater ())
