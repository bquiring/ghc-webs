module Main (main) where

-- Note [Constant specialisation] in GHC.WebCore.Transform.ConstSpec: a
-- recursive traversal passes its solve and combine functions on unchanged
-- (nofib solid's CSGtraverse_2); two callers, at two instantiations (one
-- of them the caller's own type variable), pass two pairs of known
-- functions.  Each pair gets a copy.

data Tree a = Leaf a | Node (Tree a) Int (Tree a)

trav :: q -> Tree a -> (a -> q -> r) -> (r -> Int -> r -> r) -> r
trav q (Leaf a)     solve _       = solve a q
trav q (Node l o r) solve combine = combine (trav q l solve combine) o (trav q r solve combine)
{-# NOINLINE trav #-}

count :: b -> Int -> Int
count _ q = q
{-# NOINLINE count #-}

add :: Int -> Int -> Int -> Int
add x o y = x + o + y
{-# NOINLINE add #-}

label :: Show b => b -> String -> [String]
label b q = [q ++ show b]
{-# NOINLINE label #-}

cat :: [String] -> Int -> [String] -> [String]
cat xs o ys = xs ++ [show o] ++ ys
{-# NOINLINE cat #-}

build :: Int -> b -> Tree b
build 0 b = Leaf b
build n b = Node (build (n - 1) b) n (build (n - 1) b)

total :: Tree b -> Int
total t = trav 1 t count add
{-# NOINLINE total #-}

main :: IO ()
main = do
  print (total (build 16 'x'))
  print (total (build 10 True))
  putStrLn (concat (trav "<" (build 3 (7 :: Int)) label cat))
