import os, sys
out = sys.argv[1]
P = 'poison :: String -> a\npoison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)\n{-# NOINLINE poison #-}\n'
T = {}
def t(n, comment, body, pragmas=''):
    T[n] = (comment, body, pragmas)

# ---- A. self recursion ----
t(1, "Self recursion: an accumulator that the loop passes along but never reads; its initial value is poison.", '''
loop :: Int -> Int -> Int -> Int
loop n acc dead = if n == 0 then acc else loop (n - 1) (acc + n) (dead + 1)
{-# NOINLINE loop #-}

apply :: (Int -> Int -> Int -> Int) -> Int -> Int
apply f n = f n 0 (poison "dead accumulator")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply loop 100)
''')
t(2, "Self recursion returning a pair: the second component is poison in the base case and never read.", '''
walk :: Int -> (Int, Int)
walk 0 = (0, poison "base second")
walk n = case walk (n - 1) of (a, b) -> (a + n, b + 1)
{-# NOINLINE walk #-}

main :: IO ()
main = print (fst (walk 50))
''')
t(3, "A parameter used only in a branch the run never takes: live but lazy. Poison is passed; nothing may force it early.", '''
search :: Int -> Int -> Int -> Int
search n target fallback
  | n == target = n * 2
  | n > 1000    = fallback
  | otherwise   = search (n + 1) target fallback
{-# NOINLINE search #-}

apply :: (Int -> Int -> Int -> Int) -> Int
apply f = f 0 37 (poison "fallback")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply search)
''')
t(4, "Strict in every branch but one, which returns early: the parameter is lazy; poison only reaches the early-return call.", '''
go :: Int -> Int -> Int
go 0 _ = 0
go n k = k + go (n - 1) k
{-# NOINLINE go #-}

apply :: (Int -> Int -> Int) -> Int
apply f = f 0 (poison "k on the early return") + f 3 4
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply go)
''')
t(5, "A tail-recursive loop with a dead counter and a dead flag; their initial values and increments are poison.", '''
count :: Int -> Int -> Int -> Bool -> Int
count n acc c b = if n == 0 then acc else count (n - 1) (acc + 2) (c + poison "increment") (not b)
{-# NOINLINE count #-}

main :: IO ()
main = print (count 10 0 (poison "counter") (poison "flag"))
''')
# ---- B. mutual recursion ----
t(6, "Mutual recursion (even/odd) passing a parameter neither uses.", '''
isEven, isOdd :: Int -> Int -> Bool
isEven 0 _ = True
isEven n d = isOdd (n - 1) d
isOdd 0 _ = False
isOdd n d = isEven (n - 1) d
{-# NOINLINE isEven #-}
{-# NOINLINE isOdd #-}

apply :: (Int -> Int -> Bool) -> Int -> Bool
apply f n = f n (poison "even/odd parameter")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply isEven 10, apply isOdd 7)
''')
t(7, "A three-way cycle passing a dead parameter around.", '''
a, b, c :: Int -> Int -> Int
a 0 _ = 1
a n d = 1 + b (n - 1) d
b 0 _ = 2
b n d = 2 * c (n - 1) d
c 0 _ = 3
c n d = a (n - 1) d - 1
{-# NOINLINE a #-}
{-# NOINLINE b #-}
{-# NOINLINE c #-}

apply :: (Int -> Int -> Int) -> Int -> Int
apply f n = f n (poison "cycle parameter")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply a 9, apply b 10, apply c 11)
''')
t(8, "Mutual recursion where one function uses the parameter only under a branch the run never takes: live, lazy.", '''
f, g :: Int -> Int -> Int
f 0 _ = 0
f n x = g (n - 1) x + 1
g 0 _ = 0
g n x = if n < 0 then x else f (n - 1) x * 2
{-# NOINLINE f #-}
{-# NOINLINE g #-}

apply :: (Int -> Int -> Int) -> Int -> Int
apply h n = h n (poison "rarely used")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply f 12, apply g 13)
''')
t(9, "Mutual recursion returning pairs whose second components are poison and never read.", '''
p, q :: Int -> (Int, Int)
p 0 = (1, poison "p second")
p n = case q (n - 1) of (x, y) -> (x + 1, y)
q 0 = (2, poison "q second")
q n = case p (n - 1) of (x, y) -> (x * 2, y)
{-# NOINLINE p #-}
{-# NOINLINE q #-}

main :: IO ()
main = print (fst (p 10), fst (q 11))
''')
# ---- C. higher order ----
t(10, "A local map-like loop over unknown functions that ignore their argument; the list elements are poison.", '''
mapL :: (Int -> Int) -> [Int] -> [Int]
mapL _ [] = []
mapL h (x : xs) = h x : mapL h xs
{-# NOINLINE mapL #-}

main :: IO ()
main = print (sum (mapL (\\_ -> 3) [poison "e1", poison "e2", poison "e3"]),
              sum (mapL (\\_ -> 4) [poison "e4"]))
''')
t(11, "A foldr-style fold with a combining function that ignores the accumulator; the seed is poison.", '''
foldR :: (Int -> Int -> Int) -> Int -> [Int] -> Int
foldR _ z [] = z
foldR k z (x : xs) = k x (foldR k z xs)
{-# NOINLINE foldR #-}

main :: IO ()
main = print (foldR (\\x _ -> x * 10) (poison "seed") [1, 2, 3], foldR (\\x _ -> x + 1) (poison "seed2") [7])
''')
t(12, "Continuation passing: continuations that ignore their argument; the value passed is poison.", '''
withValue :: Int -> (Int -> Int -> r) -> r
withValue n k = k n (poison "continuation argument")
{-# NOINLINE withValue #-}

main :: IO ()
main = print (withValue 5 (\\a _ -> a + 1), withValue 6 (\\a _ -> a * 3))
''')
t(13, "Functions stored in a local data structure, called with a poison argument they ignore.", '''
data Ops = Ops (Int -> Int -> Int) (Int -> Int -> Int)

ops :: Ops
ops = Ops (\\a _ -> a + 1) (\\a _ -> a * 2)
{-# NOINLINE ops #-}

run :: Ops -> Int -> Int
run (Ops f g) n = f n (poison "stored f") + g n (poison "stored g")
{-# NOINLINE run #-}

main :: IO ()
main = print (run ops 10)
''')
t(14, "Several lambdas in one web: one uses its second parameter, the others do not; poison goes only to calls that reach the others.", '''
pick :: Int -> (Int -> Int -> Int)
pick 0 = \\a b -> a + b
pick 1 = \\a _ -> a * 2
pick _ = \\a _ -> a - 1
{-# NOINLINE pick #-}

apply :: Int -> Int -> Int -> Int
apply k a b = pick k a b
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply 0 3 4, apply 1 5 (poison "pick 1"), apply 2 6 (poison "pick 2"))
''')
t(15, "A curried function with a dead middle parameter, partially applied and shared.", '''
mk :: Int -> Int -> Int -> Int
mk a _ c = a * 100 + c
{-# NOINLINE mk #-}

apply :: (Int -> Int -> Int -> Int) -> Int
apply f = let g = f 7 (poison "middle") in g 1 + g 2
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply mk)
''')
# ---- D. data structures ----
t(16, "A list of pairs whose second components are poison; only the first components are consumed.", '''
firsts :: [(Int, Int)] -> Int
firsts [] = 0
firsts ((a, _) : r) = a + firsts r
{-# NOINLINE firsts #-}

main :: IO ()
main = print (firsts [ (i, poison ("second " ++ show i)) | i <- [1 .. 20] ])
''')
t(17, "A local data type with a lazy field that is poison and never read.", '''
data T = T Int Int

build :: Int -> T
build n = T (n * 2) (poison "unread field")
{-# NOINLINE build #-}

useT :: T -> Int
useT (T a _) = a + 1
{-# NOINLINE useT #-}

main :: IO ()
main = print (sum (map (useT . build) [1 .. 10]))
''')
t(18, "A local data type with a strict field (read) and a lazy poison field (never read).", '''
data T = T !Int Int

build :: Int -> T
build n = T (n + 1) (poison "lazy field")
{-# NOINLINE build #-}

useT :: T -> Int
useT (T a _) = a
{-# NOINLINE useT #-}

main :: IO ()
main = print (sum (map (useT . build) [1 .. 10]))
''')
t(19, "A tree traversal over a local type whose payload field is poison and only the shape is used.", '''
data Tree = Leaf | Node Tree Int Tree

mkTree :: Int -> Tree
mkTree 0 = Leaf
mkTree n = Node (mkTree (n - 1)) (poison "payload") (mkTree (n - 1))
{-# NOINLINE mkTree #-}

size :: Tree -> Int
size Leaf = 0
size (Node l _ r) = size l + 1 + size r
{-# NOINLINE size #-}

main :: IO ()
main = print (size (mkTree 8))
''')
t(20, "A record whose poison field is overwritten before it is read.", '''
data R = R { ra :: Int, rb :: Int }

initial :: R
initial = R { ra = 1, rb = poison "initial rb" }
{-# NOINLINE initial #-}

step :: R -> R
step r = r { rb = ra r * 10 }
{-# NOINLINE step #-}

main :: IO ()
main = print (rb (step initial), ra initial)
''')
t(21, "A list built by recursion whose tail beyond what is consumed is poison.", '''
upTo :: Int -> Int -> [Int]
upTo n lim = if n == lim then poison "beyond the limit" else n : upTo (n + 1) lim
{-# NOINLINE upTo #-}

main :: IO ()
main = print (sum (take 10 (upTo 0 10)))
''')
t(22, "An infinite list consumed partially; every element past the prefix is poison.", '''
stream :: Int -> [Int]
stream n = n : if n >= 5 then repeat (poison "past the prefix") else stream (n + 1)
{-# NOINLINE stream #-}

main :: IO ()
main = print (take 6 (stream 0))
''')
t(23, "Maybe and Either results whose unused branches hold poison.", '''
lookupish :: Int -> Either Int Int
lookupish n = if even n then Left (n * 2) else Right (poison "right side")
{-# NOINLINE lookupish #-}

onlyLeft :: Either Int Int -> Int
onlyLeft (Left a) = a
onlyLeft (Right _) = -1
{-# NOINLINE onlyLeft #-}

maybeish :: Int -> Maybe (Int, Int)
maybeish n = Just (n, poison "maybe second")
{-# NOINLINE maybeish #-}

main :: IO ()
main = print (map (onlyLeft . lookupish) [1 .. 6], fmap fst (maybeish 4))
''')
t(24, "Nested pairs: a deep component is poison and never read.", '''
nest :: Int -> ((Int, Int), (Int, Int))
nest n = ((n, poison "deep a"), (poison "deep b", n * 3))
{-# NOINLINE nest #-}

useNest :: ((Int, Int), (Int, Int)) -> Int
useNest ((a, _), (_, d)) = a + d
{-# NOINLINE useNest #-}

main :: IO ()
main = print (sum (map (useNest . nest) [1 .. 5]))
''')
t(25, "A local product type (split and unboxed by data splitting) with a poison field never used.", '''
data P = P Int Int

mkP :: Int -> P
mkP n = P (n + 1) (poison "P second")
{-# NOINLINE mkP #-}

addP :: P -> P -> Int
addP (P a _) (P c _) = a + c
{-# NOINLINE addP #-}

main :: IO ()
main = print (sum [ addP (mkP i) (mkP (i * 2)) | i <- [1 .. 10] ])
''')
# ---- E. must evaluate (raise) ----
t(26, "Must raise: seq on an otherwise unused argument.", '''
f :: Int -> Int -> Int
f a b = b `seq` a + 1
{-# NOINLINE f #-}

apply :: (Int -> Int -> Int) -> Int
apply h = h 1 2 + h 3 (errorWithoutStackTrace "poison026: forced by seq")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply f)
''', '{-# LANGUAGE BangPatterns #-}')
t(27, "Must raise: a bang pattern on an otherwise unused parameter.", '''
f :: Int -> Int -> Int
f a !_ = a + 1
{-# NOINLINE f #-}

apply :: (Int -> Int -> Int) -> Int
apply h = h 1 2 + h 3 (errorWithoutStackTrace "poison027: forced by a bang")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply f)
''', '{-# LANGUAGE BangPatterns #-}')
t(28, "Must raise: building a strict field whose value is never read.", '''
data S = S Int !Int

mk :: Int -> S
mk n = S n (if n > 3 then errorWithoutStackTrace "poison028: strict field" else n)
{-# NOINLINE mk #-}

useS :: S -> Int
useS (S a _) = a
{-# NOINLINE useS #-}

main :: IO ()
main = print (map (useS . mk) [1 .. 5])
''')
t(29, "Must raise: a dead result component that is computed by an unlifted error.", '''
bad :: Int -> Int#
bad n = if n > 5 then errorWithoutStackTrace "poison029: unlifted component" else 0#
{-# NOINLINE bad #-}

apply :: (Int -> (# Int, Int# #)) -> [Int] -> Int
apply f xs = sum [ case f x of (# a, _ #) -> a | x <- xs ]
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply (\\x -> (# x, bad x #)) [1 .. 10])
''', '{-# LANGUAGE MagicHash, UnboxedTuples #-}\nimport GHC.Exts')
t(30, "Must raise: a case on an otherwise dead variable forces it.", '''
f :: Int -> Int -> Int
f a b = case b of _ | b > 0 -> a + 1
                    | otherwise -> a + 2
{-# NOINLINE f #-}

apply :: (Int -> Int -> Int) -> Int
apply h = h 1 2 + h 3 (errorWithoutStackTrace "poison030: scrutinised")
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply f)
''')
# ---- F. thunks and sharing ----
t(31, "A let-bound thunk used only in a branch the run never takes: strictness must not hoist it.", '''
f :: Int -> Int
f n = let t = poison "let in untaken branch" + n in if n < 0 then t else n * 2
{-# NOINLINE f #-}

main :: IO ()
main = print (map f [1 .. 5])
''')
t(32, "A thunk captured by a closure that is never called.", '''
mkClosures :: Int -> (Int, Int -> Int)
mkClosures n = let t = poison "captured" + n in (n + 1, \\k -> k + t)
{-# NOINLINE mkClosures #-}

main :: IO ()
main = print (fst (mkClosures 4))
''')
t(33, "A where-bound helper whose value is poison, used under a condition that is false.", '''
f :: Int -> Int -> Int
f a b = if a > b then helper else a + b
  where helper = poison "where helper" * 2
{-# NOINLINE f #-}

main :: IO ()
main = print (zipWith f [1 .. 5] [10 .. 14])
''')
t(34, "A lazy let used only after a guard that returns early in every run.", '''
f :: [Int] -> Int
f xs = let s = poison "after the guard" + length xs in
       case xs of
         [] -> 0
         (x : _) | x >= 0 -> x
                 | otherwise -> s
{-# NOINLINE f #-}

main :: IO ()
main = print (map f [[], [1], [2, 3]])
''')
t(35, "A dead non-terminating thunk: evaluating it would hang (the test would time out).", '''
spin :: Int -> Int
spin n = spin (n + 1)
{-# NOINLINE spin #-}

apply :: (Int -> Int -> Int) -> Int
apply h = h 5 (spin 0)
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply (\\a _ -> a * 4))
''')
# ---- G. results ----
t(36, "An unboxed tuple result with a poison component no caller uses.", '''
apply :: (Int -> (# Int, Int #)) -> [Int] -> Int
apply f xs = sum [ case f x of (# a, _ #) -> a | x <- xs ]
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply (\\x -> (# x + 1, poison "component" #)) [1 .. 10])
''', '{-# LANGUAGE UnboxedTuples #-}')
t(37, "A boxed product result across recursion: the second field is poison and never read by any caller.", '''
stats :: [Int] -> (Int, Int)
stats [] = (0, poison "stats second")
stats (x : xs) = case stats xs of (s, m) -> (s + x, max m x)
{-# NOINLINE stats #-}

apply :: ([Int] -> (Int, Int)) -> Int
apply f = case f [1 .. 10] of (s, _) -> s
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply stats)
''')
t(38, "A result component one caller forces and another does not: lazy at the producer. The poison reaches only the lazy caller.", '''
apply1, apply2 :: (Int -> (Int, Int)) -> Int -> Int
apply1 f n = case f n of (a, b) -> a + b
apply2 f n = case f n of (a, _) -> a
{-# NOINLINE apply1 #-}
{-# NOINLINE apply2 #-}

mk :: Int -> (Int, Int)
mk n = (n, if n > 100 then poison "lazily consumed second" else n * 2)
{-# NOINLINE mk #-}

main :: IO ()
main = print (apply1 mk 3, apply2 mk 500)
''')
t(39, "A caller that forces the first field only in one branch: the field is lazy, the poison in the other branch is never forced.", '''
apply :: (Int -> (Int, Int)) -> Int -> Int
apply f n = case f n of (a, b) -> if n > 0 then b else a
{-# NOINLINE apply #-}

mk :: Int -> (Int, Int)
mk n = (if n > 0 then poison "first field" else n, n + 1)
{-# NOINLINE mk #-}

main :: IO ()
main = print (apply mk 4, apply mk 0)
''')
t(40, "A join point returning a tuple whose second component is poison in one branch and never read.", '''
step :: Int -> (# Int, Int #)
step x =
  let j :: Int -> (# Int, Int #)
      j k = (# k + 1, if k > 4 then poison "join component" else k #)
      {-# NOINLINE j #-}
  in if even x then j (x * 2) else j (x + 3)

apply :: (Int -> (# Int, Int #)) -> [Int] -> Int
apply f xs = sum [ case f x of (# a, _ #) -> a | x <- xs ]
{-# NOINLINE apply #-}

main :: IO ()
main = print (apply step [1 .. 10])
''', '{-# LANGUAGE UnboxedTuples #-}')

os.makedirs(out, exist_ok=True)
for n, (comment, body, prag) in T.items():
    name = 'poison%03d' % n
    lines = [ '-- ' + l for l in wrap(comment) ] if False else None
    import textwrap
    head = '\n'.join('-- ' + l for l in textwrap.wrap(comment + ' (Deadness and strictness: the program must behave as it does unoptimised.)', 74))
    prags = [p for p in prag.split('\n') if p.startswith('{-#')]
    imps = [p for p in prag.split('\n') if p.startswith('import')]
    src = head + '\n' + '\n'.join(prags) + ('\n' if prags else '') + 'module Main (main) where\n\n' + ('\n'.join(imps) + '\n\n' if imps else '') + P + body
    open(os.path.join(out, name + '.hs'), 'w').write(src)
print(len(T))
