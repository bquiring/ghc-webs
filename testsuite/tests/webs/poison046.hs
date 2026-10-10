-- A field carried round a recursion by an unknown join function and never
-- read at the end: dead (useless elimination fills it), and vacuously strict
-- for web strictness (each consumer returns it in the same field), which must
-- not evaluate the filler (from nofib spectral/hartel/parstof).  (Deadness
-- and strictness: the program must behave as it does unoptimised.)
module Main (main) where

data R a = Fail | Succ a [Int]

rep :: (a -> a -> a) -> a -> ([Int] -> R a) -> [Int] -> R a
rep join z p ts =
  case p ts of
    Fail -> Succ z ts
    Succ v rest -> case rep join z p rest of
                     Succ lv rest' -> Succ (join v lv) rest'
                     Fail -> Fail
{-# NOINLINE rep #-}

item :: [Int] -> R Int
item (t : ts) | t > 0 = Succ (t * 2) ts
item _ = Fail
{-# NOINLINE item #-}

seqR :: (a -> b -> c) -> ([Int] -> R a) -> ([Int] -> R b) -> [Int] -> R c
seqR f p q ts = case p ts of
  Fail -> Fail
  Succ a r -> case q r of
                Fail -> Fail
                Succ b r' -> Succ (f a b) r'
{-# NOINLINE seqR #-}

rest :: R a -> [Int]
rest (Succ _ r) = r
rest Fail = []
{-# NOINLINE rest #-}

main :: IO ()
main = do
  print (rest (rep (+) 0 item [3, 2, 1, 0, 9]))
  print (rest (seqR (\_ b -> b) item (rep (*) 1 item) [5, 4, 0, 7]))
