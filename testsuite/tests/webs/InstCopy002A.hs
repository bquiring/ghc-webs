-- fgl's LPath in miniature (Note [Names of newtype copies] in
-- GHC.WebCore.DataSplit): an exported newtype over a list, with
-- hand-written instances; with their copies the newtype splits, and its
-- copy is written to the interface beside it
module InstCopy002A (LPath(..), LNode, mk) where

type LNode a = (Int, a)

newtype LPath a = LP { unLPath :: [LNode a] }

instance (Show a) => Show (LPath a) where
  show (LP xs) = show xs

instance (Eq a) => Eq (LPath a) where
  (LP [])        == (LP [])        = True
  (LP ((_,x):_)) == (LP ((_,y):_)) = x==y
  (LP _)         == (LP _)         = False

instance (Ord a) => Ord (LPath a) where
  compare (LP [])        (LP [])        = EQ
  compare (LP ((_,x):_)) (LP ((_,y):_)) = compare x y
  compare _ _ = error "LPath: cannot compare two empty paths"

mk :: Int -> a -> LPath a
mk n x = LP [ (i, x) | i <- [n, n - 1 .. 1] ]
