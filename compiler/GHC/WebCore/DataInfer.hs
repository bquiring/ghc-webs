{-# LANGUAGE BangPatterns #-}
-- | Inferring which copies of a data type must be the same, by unification:
-- the pairs that Data Lint records, without type-checking the program.
--
-- See Note [Inferring copy pairs].
module GHC.WebCore.DataInfer
  ( inferCopyPairs
  , solveCopies
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.Coercion ( coercionLKind, coercionRKind, coercionType )
import GHC.Core.DataCon ( dataConRepType )
import GHC.Core.TyCo.Rep
import GHC.Core.Type
import GHC.Core.Utils ( mkLamType )
import GHC.Core.TyCon ( TyCon )

import GHC.Types.Id ( idType )
import GHC.Types.Literal ( literalType )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set

import GHC.Data.UnionFind ( Point, Link(..), fresh, repr, union, readPoint )

import Control.Monad.ST
import Data.STRef

import GHC.Data.Bag
import GHC.Utils.Panic ( panic )

import GHC.WebCore.DataCopy ( Copies, copyPairs, copyOriginal )

{- Note [Inferring copy pairs]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Data splitting needs the pairs of copies that the annotated program forces
together (Note [Splitting data types] in GHC.WebCore.DataSplit).  Data Lint
(GHC.WebCore.DataLint, a copy of Core Lint) records them as it type-checks
the program: wherever it requires two types to be equal, it calls copyPairs
on them.  But the program is already well typed up to copies, so the checks
themselves are not needed, only the comparisons.

inferCopyPairs walks the program once, computing each expression's type,
and calls copyPairs at the places where Data Lint compares types:

  * a binder's type against its right-hand side's (let, letrec, join points);
  * a function's argument type against the argument's;
  * a case binder's type against the scrutinee's;
  * a constructor alternative: the constructor's type, instantiated at the
    case binder's type arguments, against the pattern binders' types, and
    its result against the scrutinee's;
  * each alternative's type against the case's;
  * a cast's left kind against its expression's type;
  * inside coercions: a TransCo's right kind against the next one's left
    kind, and the kinds of GRefl and ForAllCo.

Occurrences need nothing: annotation gives an occurrence its binder's Id
(mapProgram in GHC.WebCore.DataSplit), so their types are the same.
Imported functions, exported and pinned binders have the original types, so
a copy that meets one of them is paired with the original, as in Data Lint.

This is the default; -fcore-webs-data-lint-pairs takes the pairs from Data
Lint instead, and -fcore-webs-data-infer-check compares the classes from
both on every module (they were the same on all of nofib, 469 modules, and
the data-splitting tests, 2026-10-14).
-}

-- | The pairs of type constructors (copies, or a copy and its original)
-- that the program forces to be the same.  Note [Inferring copy pairs]
inferCopyPairs :: Copies -> CoreProgram -> Bag (TyCon, TyCon)
inferCopyPairs copies binds = foldl' (flip bind) emptyBag binds
  where
    unify :: Type -> Type -> Bag (TyCon, TyCon) -> Bag (TyCon, TyCon)
    unify t1 t2 !acc = copyPairs copies t1 t2 `unionBags` acc

    bind :: CoreBind -> Bag (TyCon, TyCon) -> Bag (TyCon, TyCon)
    bind (NonRec b e) acc = let (t, acc') = expr e acc in unify (idType b) t acc'
    bind (Rec prs)    acc = foldl' (\a (b, e) -> let (t, a') = expr e a in unify (idType b) t a')
                                   acc prs

    -- The expression's type, and the pairs so far
    expr :: CoreExpr -> Bag (TyCon, TyCon) -> (Type, Bag (TyCon, TyCon))
    expr e !acc = case e of
      Var v       -> (idType v, acc)
      Lit l       -> (literalType l, acc)
      Type t      -> (typeKind t, acc)
      Coercion co -> (coercionType co, coercion co acc)
      App {}      -> app e acc
      Lam b body  -> let (t, acc') = expr body acc in (mkLamType b t, acc')
      Let b body  -> expr body (bind b acc)
      Case scrut b ty alts
        -> let (st, acc1) = expr scrut acc
               acc2       = unify (idType b) st acc1
           in (ty, foldl' (\a al -> alt b st ty al a) acc2 alts)
      Cast x co
        -> let (t, acc1) = expr x acc
           in (coercionRKind co, unify (coercionLKind co) t (coercion co acc1))
      Tick _ x    -> expr x acc
      WebLam {}   -> (webForm, acc)
      WebApp {}   -> (webForm, acc)

    webForm = panic "DataInfer: web form"

    -- An application: the function's type, instantiated at type arguments,
    -- and each value argument against the argument type
    app e acc = go (expr f acc) args
      where
        (f, args) = collectArgs e
        go (ft, a) [] = (ft, a)
        go (ft, a) (Type t : rest) = go (piResultTy ft t, a) rest
        go (ft, a) (arg : rest)
          = let (at, a1) = expr arg a
            in case splitFunTy_maybe ft of
                 Just (_, _, arg_ty, res_ty) -> go (res_ty, unify arg_ty at a1) rest
                 Nothing -> go (piResultTy ft at, a1) rest   -- a coercion argument
                                                              -- to a forall over it

    -- A case alternative (Data Lint: lintCoreAlt, lintAltBinders)
    alt case_bndr scrut_ty ty (Alt con bs rhs) acc
      = let (rt, acc1) = expr rhs acc
            acc2       = unify rt ty acc1
        in case con of
             DataAlt dc
               | Just (_, tc_args) <- splitTyConApp_maybe (idType case_bndr)
               -> pattern (piResultTys (dataConRepType dc) tc_args) bs acc2
             _ -> acc2
      where
        pattern con_ty [] a = unify con_ty scrut_ty a
        pattern con_ty (v : vs) a
          | isTyVar v = pattern (piResultTy con_ty (mkTyVarTy v)) vs a
          | Just (_, _, arg_ty, res_ty) <- splitFunTy_maybe con_ty
          = pattern res_ty vs (unify arg_ty (varType v) a)
          | otherwise   -- a coercion binder of a forall
          = pattern (piResultTy con_ty (mkCoercionTy (CoVarCo v))) vs a

    -- Inside a coercion (Data Lint: lintCoercion)
    coercion :: Coercion -> Bag (TyCon, TyCon) -> Bag (TyCon, TyCon)
    coercion co !acc = case co of
      Refl {}                 -> acc
      GRefl _ _ MRefl         -> acc
      GRefl _ t (MCo kco)     -> unify (typeKind t) (coercionLKind kco) (coercion kco acc)
      TyConAppCo _ _ cos      -> foldl' (flip coercion) acc cos
      AppCo c1 c2             -> coercion c2 (coercion c1 acc)
      ForAllCo { fco_tcv = tcv, fco_kind = kco, fco_body = body }
                              -> unify (varType tcv) (coercionLKind kco)
                                       (coercion body (coercion kco acc))
      FunCo { fco_mult = m, fco_arg = a, fco_res = r }
                              -> coercion r (coercion a (coercion m acc))
      CoVarCo {}              -> acc
      AxiomCo _ cos           -> foldl' (flip coercion) acc cos
      UnivCo { uco_deps = cos } -> foldl' (flip coercion) acc cos
      SymCo c                 -> coercion c acc
      TransCo c1 c2           -> unify (coercionRKind c1) (coercionLKind c2)
                                       (coercion c2 (coercion c1 acc))
      SelCo _ c               -> coercion c acc
      LRCo _ c                -> coercion c acc
      InstCo c arg            -> coercion arg (coercion c acc)
      KindCo c                -> coercion c acc
      SubCo c                 -> coercion c acc
      HoleCo {}               -> acc

{- Note [Solving copy classes online]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The classes of copies are the connected components of the pairs, closed
under congruence for newtype copies (Note [Splitting newtypes] in
GHC.WebCore.DataSplit): when two newtype copies are in one class, so are
their children, pairwise; and when a newtype copy's class meets the
original, each child meets its own original.

solveCopies does this with a union-find whose classes carry a descriptor:
one member's children (if it is a newtype copy) and whether the class
contains an original.  Merging two classes merges the descriptors and
queues the pairs congruence asks for: the two children lists pairwise, or
one list against its originals when the other class contains an original.
So each merge does its congruence once, when it happens.  (It replaced
computing the components again for each round of congruence, up to 20
rounds, which dominated splitting on ordinary modules.)

A node that only congruence brings in (an original paired with a child)
counts as a member, as before.
-}

data Desc = Desc { d_rep      :: TyCon
                 , d_children :: Maybe [TyCon]
                 , d_original :: Bool }

-- | The classes of the pairs, closed under congruence for newtype copies'
-- children: each node's representative, and the nodes (the given ones, the
-- pairs', and the originals congruence brings in).
-- Note [Solving copy classes online]
solveCopies :: Copies -> (TyCon -> Maybe [TyCon]) -> [TyCon] -> [(TyCon, TyCon)]
            -> (UniqFM TyCon TyCon, [TyCon])
solveCopies copies children nodes0 pairs = runST $ do
  { pts  <- newSTRef (emptyUFM :: UniqFM TyCon (Point s Desc))
  ; seen <- newSTRef (mkUniqSet nodes0)
  ; let is_copy c = c `elemUFM` copies
        point c = do { m <- readSTRef pts
                     ; case lookupUFM m c of
                         Just p  -> return p
                         Nothing -> do { p <- fresh (Desc c (children c) (not (is_copy c)))
                                       ; writeSTRef pts (addToUFM m c p)
                                       ; modifySTRef' seen (`addOneToUniqSet` c)
                                       ; return p } }
        desc p = do { r <- repr p
                    ; l <- readPoint r
                    ; case l of
                        Info _ d -> readSTRef d
                        Link _   -> panic "solveCopies: repr" }
        set_desc p d = do { r <- repr p
                          ; l <- readPoint r
                          ; case l of
                              Info _ dref -> writeSTRef dref d
                              Link _      -> panic "solveCopies: repr" }
        -- congruence: the pairs a merge of these two classes asks for
        cong (Desc _ (Just ca) _) (Desc _ (Just cb) _) = zip ca cb
        cong (Desc _ (Just ca) _) (Desc _ Nothing True) = [ (c, copyOriginal copies c) | c <- ca ]
        cong (Desc _ Nothing True) (Desc _ (Just cb) _) = [ (c, copyOriginal copies c) | c <- cb ]
        cong _ _ = []
        go [] = return ()
        go ((a, b) : rest)
          = do { pa <- point a; pb <- point b
               ; ra <- repr pa; rb <- repr pb
               ; if ra == rb then go rest else do
               { da <- desc ra; db <- desc rb
               ; union ra rb
               ; set_desc ra (Desc (d_rep da) (maybe (d_children db) Just (d_children da))
                                   (d_original da || d_original db))
               ; go (cong da db ++ rest) } }
  ; mapM_ point nodes0
  ; go pairs
  ; m  <- readSTRef pts
  ; ns <- nonDetEltsUniqSet <$> readSTRef seen
  ; reps <- mapM (\n -> case lookupUFM m n of
                          Just p  -> (,) n . d_rep <$> desc p
                          Nothing -> return (n, n)) ns
  ; return (listToUFM reps, ns) }
