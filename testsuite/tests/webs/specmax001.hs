import SpecMax001A
import Data.Word
import Data.Int

main :: IO ()
main = do
  print (total 0 [1, 2, 3 :: Int])
  print (total 0 [1, 2, 3 :: Integer])
  print (total 0 [1, 2, 3 :: Double])
  print (total 0 [1, 2, 3 :: Word])
  print (total 0 [1, 2, 3 :: Int8])
  print (spread [3, 1, 4, 1, 5, 9, 2, 6 :: Int])
  print (spread [3, 1, 4, 1, 5, 9, 2, 6 :: Double])
