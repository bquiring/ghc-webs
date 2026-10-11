-- A zipper, after uniplate's Data.Generics.Uniplate.Zipper.  Zipper is
-- exported abstractly and mentions ZipN, a local type whose field holds
-- functions.  Result raising raises their web, and ZipN is rebuilt with the
-- new field; Zipper, which mentions it, must be rebuilt too, or
-- worker/wrapper unboxes a Zipper through the old ZipN (Core Lint error).
-- Note [Signatures follow the transformations] in GHC.WebCore.HiddenFields.
module HField005A (Zipper, Str(..), zipper, up, down, hole, fromZipper) where

data Str a = Zero | One a | Two (Str a) (Str a)

data Zipper from to = Zipper (Str to -> from) (ZipN to)

rezipp :: (ZipN to -> Maybe (ZipN to)) -> Zipper from to -> Maybe (Zipper from to)
rezipp f (Zipper a b) = fmap (Zipper a) (f b)

zipper :: (to -> Str to) -> to -> Zipper to to
zipper _ x = case zip1 (One x) of
  Just z  -> Zipper (\(One y) -> y) (ZipN [] z)
  Nothing -> error "zipper"

down :: (to -> Str to) -> Zipper from to -> Maybe (Zipper from to)
down kids = rezipp (downN kids)

up :: Zipper from to -> Maybe (Zipper from to)
up = rezipp upN

hole :: Zipper from to -> to
hole (Zipper _ (ZipN _ z)) = hole1 z

fromZipper :: Zipper from to -> from
fromZipper (Zipper r z) = r (top1 (topN z))

data ZipN x = ZipN [Str x -> Zip1 x] (Zip1 x)

upN :: ZipN x -> Maybe (ZipN x)
upN (ZipN [] _) = Nothing
upN (ZipN (p:ps) x) = Just (ZipN ps (p (top1 x)))

topN :: ZipN x -> Zip1 x
topN (ZipN [] x) = x
topN z = maybe (error "topN") topN (upN z)

downN :: (x -> Str x) -> ZipN x -> Maybe (ZipN x)
downN kids (ZipN ps x) = fmap (ZipN ((replace1 x . gen) : ps)) (zip1 cs)
  where cs = kids (hole1 x)
        gen s = rebuild (kids (hole1 x)) s
        rebuild Zero _ = hole1 x
        rebuild _ s = case s of { One y -> y; _ -> hole1 x }

data Diff1 a = TwoLeft (Str a) | TwoRight (Str a)

undiff1 :: Str a -> Diff1 a -> Str a
undiff1 r (TwoLeft  l) = Two l r
undiff1 l (TwoRight r) = Two l r

data Zip1 a = Zip1 [Diff1 a] a

zip1 :: Str x -> Maybe (Zip1 x)
zip1 = insert1 True []

insert1 :: Bool -> [Diff1 a] -> Str a -> Maybe (Zip1 a)
insert1 _ _ Zero = Nothing
insert1 _ c (One x) = Just (Zip1 c x)
insert1 leftmost c (Two l r) = if leftmost then ll `orElse` rr else rr `orElse` ll
  where ll = insert1 leftmost (TwoRight r : c) l
        rr = insert1 leftmost (TwoLeft  l : c) r
        orElse Nothing b = b
        orElse a _ = a

top1 :: Zip1 a -> Str a
top1 (Zip1 p x) = f p (One x)
  where f :: [Diff1 a] -> Str a -> Str a
        f [] y = y
        f (q:qs) y = f qs (y `undiff1` q)

hole1 :: Zip1 a -> a
hole1 (Zip1 _ x) = x

replace1 :: Zip1 a -> a -> Zip1 a
replace1 (Zip1 p _) = Zip1 p
