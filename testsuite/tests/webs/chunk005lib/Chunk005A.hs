module Chunk005A (T(..), size, mk) where
import Chunk005B
data T = Leaf | Node T T
size :: T -> Int
size Leaf = 1
size (Node a b) = size a + size b
mk :: Int -> T
mk 0 = Leaf
mk n = Node (mk (n - 1)) (mk (n `div` 2))
-- uses B, which uses A's boot interface
total :: [T] -> Int
total = sumWith size
