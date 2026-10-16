module Main (main) where

import Chunk012B

main :: IO ()
main = runBoth (noBinders (pure 41)) >>= print
