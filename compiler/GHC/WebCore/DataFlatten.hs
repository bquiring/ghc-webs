-- | Unboxing the fields of split data types: a product field that every
-- construction fills with a value, and every match only takes apart, holds
-- the product's components instead.
--
-- See Note [Flattening fields].
module GHC.WebCore.DataFlatten
  ( flattenFields
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.DataCon
import GHC.Core.Make ( mkCoreConApps )
import GHC.Core.Multiplicity ( Scaled(..), scaledThing )
import GHC.Core.TyCo.Rep
import GHC.Core.TyCon
import GHC.Core.Type
import GHC.Core.Utils ( exprIsHNF, exprOkForSpeculation, mkSingleAltCase )

import GHC.Data.FastString ( fsLit )

import GHC.Types.Id
import GHC.Types.Id.Make ( mkDataConWorkId )
import GHC.Types.Name
import GHC.Types.Name.Env ( emptyNameEnv )
import GHC.Types.SourceText ( SourceText(..) )
import GHC.Types.SrcLoc ( noSrcSpan )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Types.Basic ( Boxity(..) )
import GHC.Types.Demand ( Demand(..), SubDemand(..), splitDmdSig, isStrict, isStrUsedDmd, isStrictDmd )
import GHC.Types.Tickish ( GenTickish(..) )
import GHC.Core.FVs ( exprFreeVarsList )

import GHC.Unit.Module ( Module )
import GHC.Utils.Outputable
import GHC.Utils.Panic ( panic )

import GHC.WebCore.DataSplit ( mapTyCons, mapTyConsCo )
import GHC.WebCore.DataCopy ( UnboxOpts(..) )
import Data.List ( sortOn )
import GHC.WebCore.Transform.ArityRaise ( productCon, replaceCases )

import Control.Monad ( forM, foldM )
import Data.Functor.Identity ( runIdentity )
import Data.Maybe ( isNothing, fromMaybe, isJust )

{- Note [Unboxable fields]
~~~~~~~~~~~~~~~~~~~~~~~~~~
Which fields can be unboxed is a greatest fixpoint over the candidate
fields (K, i).  A field stays unboxable while

  * every construction of K is saturated and passes in field i a value, or
    the pattern variable of an unboxable field (K', j) (which is rebuilt as
    a constructor application, a value); and
  * every use of field i's pattern variable in a match on K is
      - the scrutinee of a case (a projection),
      - an argument to a call whose callee's demand signature says it is
        strict in it and uses it unboxed (worker/wrapper will take the
        rebuilt box apart again, and the simplifier removes it), or
      - an argument to an unboxable field (K'', j) of a saturated
        construction.

Start from every candidate field and remove the ones that fail, until
nothing changes.  A removed field stays a pointer to a boxed value.
-}

{- Note [Bounding unboxing]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
Unboxing a field copies its value's contents into the cell.  If one boxed
value is shared by many cells, each cell now holds its own copy; and when an
unboxed field's value flows into another structure that keeps it boxed, or
into a lazy position, it is rebuilt -- a copy, each time.  Two controls:

  * -fcore-webs-max-unbox-size=K (default 4): a constructor's size in words,
    after unboxing, stays within K times its size as split (pointers and
    unboxed fields count one word each), over all rounds.  So memory per
    cell grows at most K-fold.  Applied to the candidates before the
    fixpoint (dropping the largest expansions first), so that the fixpoint
    only removes: other fields may rely on a field being unboxed.
  * -fcore-webs-unbox-nested (off by default): a field may depend on the
    unboxing of another data structure's field -- a construction passing
    another unboxed field's pattern variable, or a match storing the field
    into another unboxed field.  Off, a field is unboxable only from its own
    constructions and uses; values that move between structures stay boxed.
-}

{- Note [Strictly eliminated fields]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A field whose every match is strict in it may still never be evaluated:
strictness at the elimination says nothing about a value that is built but
never eliminated, and a constructor application is a value, allocated as
soon as its context runs (let p = (expensive, 1) in if b then fst p else 0).
So evaluating the field when the value is built is safe only if we also know
the value will be eliminated, strictly.  Function webs do not have this
problem: a lambda is entered exactly when it is called.  Data is built at
one time and eliminated at another.

A field (K, i) of a split type is strictly eliminated if

  (a) every construction of K is built where its value is demanded: in
      result position (a function's body, a case alternative, the body of a
      let: built when the value is demanded), as a case scrutinee, as the
      right-hand side of a strict let, as a strict argument of a call; or in
      a field (K', j) that is itself strictly eliminated (the fields of a
      constructor are allocated with it).  Not in a lazy let, a lazy
      argument, a recursive let, or at the top level (static data).  A
      non-value expression in a lazy position is a thunk: what is built
      inside it is built when it is forced, which is demanded.
  (b) every case on the type -- the split type is local and not exposed, so
      these are all the places its values are demanded -- has an explicit K
      alternative whose pattern variable for field i is strict.

Then whenever a K value is built, its field i will be evaluated, and
evaluating it at construction only moves the evaluation earlier (as
call-by-value does for a strict argument: GHC's strictness analysis takes
the same liberty with which exception is raised first).  So a construction
may pass a thunk in such a field, and flattening evaluates it.  The
greatest fixpoint over the fields (because of (K', j) in (a)).
-}

{- Note [Eager unboxing]
~~~~~~~~~~~~~~~~~~~~~~~~~
With -fcore-webs-data-unbox-eager, a construction may also pass an
unevaluated expression in an unboxable field, if every match on the
constructor is strict in the field (its pattern variable's demand, from
demand analysis).  The construction then evaluates it (case e of P ys -> K
.. ys ..), earlier than the program did.  This is not semantics-preserving
in general: a value built but never matched has its field evaluated anyway,
which may fail or diverge where the program did not (e.g. take 0 of a list
whose element is bottom).  Space is bounded (at worst the box, built
earlier), so the flag is an experiment, off by default.
-}

{- Note [Flattening fields]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
With -fcore-webs-data-unbox, after splitting (Note [Splitting data types] in
GHC.WebCore.DataSplit), a field of a split type S's constructor K whose type
is a product P (one constructor P, no existentials, no wrapper: Int, a pair,
...) holds P's components instead, when

  * every occurrence of K's worker is saturated, and passes a value (exprIsHNF:
    a constructor application, or a variable bound to one) in the field, or an
    expression that is cheap and cannot fail (exprOkForSpeculation), which can
    be evaluated early without changing the program's meaning; and
  * no match on K needs the boxed value: see Note [Unboxable fields] (a
    greatest fixpoint: projections, arguments that callees unbox, and
    arguments to other unboxable fields).

Then
    K .. e ..                      ==>  case e of P ys -> K' .. ys ..
    case x of K .. f .. -> rhs     ==>  case x of K' .. ys .. -> rhs[ys/case f of P zs]

Taking e apart evaluates nothing (it is a value), and no match rebuilds the
box, so nothing is evaluated or allocated that was not before; each K value
holds one box fewer.  This is the field version of constructed-argument
raising (Note [Arity raising] in GHC.WebCore.Transform.ArityRaise).  An Int
field becomes an Int# field; a pair field becomes two fields.

S is local and not exposed, so no other code builds or matches it.  Fields
whose type mentions S itself (recursive fields) are not flattened.
-}

-- | What a construction passes in a candidate field
data ArgFact = AValue              -- ^ a value (Note [Flattening fields])
         | APat DataCon Int    -- ^ the pattern variable of another candidate field
         | AOther String       -- ^ something else: what it is

-- | A use of a field's pattern variable in a match
data Use = UScrut              -- ^ the scrutinee of a case
         | UStrictArg          -- ^ an argument a callee is strict in and unboxes
         | UConArg DataCon Int -- ^ an argument to another candidate field
         | UBoxed String       -- ^ any other use: what it is

-- | The context a constructor application is built in
-- (Note [Strictly eliminated fields])
data Ctx = CDemanded            -- ^ built when its value is demanded
         | CAllocated           -- ^ allocated whether or not it is demanded
         | CField DataCon Int   -- ^ in a field of another candidate constructor

data Facts = Facts [(DataCon, Maybe [ArgFact], Ctx)] [(DataCon, Int, [Use], Bool)]
                   [(TyCon, [(DataCon, [Bool])])]

-- | What happens to a field
data Field = Keep | Flatten DataCon [Type]   -- ^ P's constructor and type arguments

-- | Per split type: its constructors' field plans (by tag), if any is flattened
type Plans = UniqFM TyCon [(DataCon, [Field])]

flattenFields :: UnboxOpts -> Module -> UniqSupply -> [TyCon] -> CoreProgram
              -> (CoreProgram, [TyCon], SDoc)
flattenFields opts this_mod us tcs binds
  | isNullUFM plans = (binds, tcs, dump)
  | otherwise       = (initUs_ us2 (mapM rw_bind binds), map new_tc tcs, dump)
  where
    (us1, us2) = splitUniqSupply us
    cands = mkUniqSet tcs
    _ = cands

    -- Candidate fields: products, not recursive
    eager  = uo_eager opts
    nested = uo_nested opts

    -- Note [Bounding unboxing]: a candidate must keep its constructor within
    -- the size bound, even if every candidate of the constructor is unboxed
    candidate :: DataCon -> Int -> Bool
    candidate dc i = local_candidate dc i && i `elem` within_bound dc
    within_bound dc
      = go_b (sortOn (\(_, n) -> n) [ (i, expansion dc i) | i <- all_fields dc, local_candidate dc i ])
             (dataConRepArity dc)
      where
        budget = uo_max_size opts * fromMaybe (dataConRepArity dc)
                                              (lookup (occNameString (getOccName dc)) (uo_orig_sizes opts))
        go_b [] _ = []
        go_b ((i, n) : rest) size
          | size - 1 + n <= budget = i : go_b rest (size - 1 + n)
          | otherwise              = go_b rest size
    expansion dc i = case drop i (dataConOrigArgTys dc) of
      (Scaled _ t : _) | Just (_, _, pdc) <- productCon (coreFullView t) -> dataConRepArity pdc
      _ -> 1

    local_candidate :: DataCon -> Int -> Bool
    local_candidate dc i = case drop i (dataConOrigArgTys dc) of
      (Scaled _ t : _)
        | Just (ptc, _, pdc) <- productCon (coreFullView t)
        , ptc /= dataConTyCon dc
        , isNothing (dataConWrapId_maybe pdc)
        , all (typeHasFixedRuntimeRep . scaledThing) (dataConOrigArgTys pdc)
        -> True
      _ -> False

    -- Facts (Note [Unboxable fields]): what each construction passes in each
    -- field and in what context it is built (Note [Strictly eliminated
    -- fields]), how each match uses each field, and which constructors each
    -- case on a candidate type has (with the strictness of their fields)
    cons_facts  :: [(DataCon, Maybe [ArgFact], Ctx)]  -- Nothing: unsaturated
    match_facts :: [(DataCon, Int, [Use], Bool)]      -- Bool: the match is strict in it
    case_facts  :: [(TyCon, [(DataCon, [Bool])])]
    Facts cons_facts match_facts case_facts
      = foldr (go_top emptyVarSet emptyVarEnv) (Facts [] [] []) binds

    is_cand_con dc = dataConTyCon dc `elementOfUniqSet` cands
    all_fields dc = [0 .. dataConRepArity dc - 1]

    -- A top-level binding: a function's body is demanded when it is called;
    -- a constructor application is static data, allocated regardless
    go_top ev pv bind acc = foldr (\(_, e) -> go_pos CAllocated ev pv e) acc (flattenBinds [bind])

    -- An expression in a position of context c: only a constructor
    -- application there is built in that context; anything else that is not
    -- a value is a thunk, whose insides run when it is forced (demanded)
    go_pos c ev pv e
      | is_con_app e = go c ev pv e
      | otherwise    = go CDemanded ev pv e
    is_con_app e = case collectArgs (strip e) of
      (Var v, _) -> isJust (isDataConWorkId_maybe v)
      _          -> False
    strip (Tick _ e) = strip e
    strip (Cast e _) = strip e
    strip e          = e

    -- ev: variables known to be evaluated (case binders);
    -- pv: pattern variables of candidate constructors' fields;
    -- c: the context the expression is evaluated in
    go c ev pv expr acc@(Facts cf mf kf) = case expr of
      App {}
        | (Var v, args) <- collectArgs expr
        , Just dc <- isDataConWorkId_maybe v
        -> let vals = [ a | a <- args, not (isTypeArg a) ]
               cand = is_cand_con dc
               -- a constructor's fields are allocated with it
               field_ctx j | cand      = CField dc j
                           | otherwise = CAllocated
               acc' = foldr (\(j, a) -> go_pos (field_ctx j) ev pv a) acc (zip [0 ..] vals)
               fact | length vals == dataConRepArity dc = Just (map (arg_fact ev pv) vals)
                    | otherwise                          = Nothing
           in if cand then add_con (dc, fact, c) acc' else acc'
        | (Var f, args) <- collectArgs expr
        -> let vals = [ a | a <- args, not (isTypeArg a) ]
               (ds, _) = splitDmdSig (idDmdSig f)
               saturated = length vals >= length ds
               arg_ctx j | saturated, Just d <- index j ds, isStrictDmd d = CDemanded
                         | otherwise                                      = CAllocated
           in foldr (\(j, a) -> go_pos (arg_ctx j) ev pv a) acc (zip [0 ..] vals)
      Var v
        | Just dc <- isDataConWorkId_maybe v, is_cand_con dc
        , dataConRepArity dc > 0
        -> add_con (dc, Nothing, c) acc
        | Just dc <- isDataConWorkId_maybe v, is_cand_con dc
        -> add_con (dc, Just [], c) acc
      App f a     -> go CDemanded ev pv f (go_pos CAllocated ev pv a acc)
      Lam _ e     -> go CDemanded ev pv e acc          -- run when applied
      Let (NonRec b rhs) e
        -> let rhs_ctx | isStrUsedDmd (idDemandInfo b) = c
                       | otherwise                     = CAllocated
           in go_pos rhs_ctx ev pv rhs (go c ev pv e acc)
      Let (Rec prs) e
        -> foldr (\(_, r) -> go_pos CAllocated ev pv r) (go c ev pv e acc) prs
      Case e b _ alts
        -> let ev' = extendVarSet ev b
               kf' | Just (tc, _) <- splitTyConApp_maybe (idType b)
                   , tc `elementOfUniqSet` cands
                   = (tc, [ (dc, map (isStrUsedDmd . idDemandInfo) (filter isId bs))
                          | Alt (DataAlt dc) bs _ <- alts ]) : kf
                   | otherwise = kf
           in go CDemanded ev pv e $
              foldr (\(Alt con bs rhs) a -> alt c ev' pv con bs rhs a) (Facts cf mf kf') alts
      Cast e _    -> go c ev pv e acc
      Tick _ e    -> go c ev pv e acc
      _           -> acc

    add_con f (Facts cf mf kf) = Facts (f : cf) mf kf

    alt c ev pv (DataAlt dc) bs rhs acc
      | is_cand_con dc
      = let fbs = filter isId bs
            pv' = extendVarEnvList pv [ (b, (dc, i)) | (i, b) <- zip [0 ..] fbs ]
            Facts cf mf kf = go c ev pv' rhs acc
        in Facts cf ([ (dc, i, usesOf b rhs, isStrUsedDmd (idDemandInfo b))
                     | (i, b) <- zip [0 ..] fbs, candidate dc i ] ++ mf) kf
    alt c ev pv _ _ rhs acc = go c ev pv rhs acc

    -- Note [Strictly eliminated fields]: the greatest fixpoint of the fields
    -- (K, i) such that every construction of K is built where it is
    -- demanded (or in a strictly eliminated field), and every case on K's
    -- type has a K alternative that is strict in field i
    strictly_eliminated :: UniqFM DataCon [Int]
    strictly_eliminated = se_fix (listToUFM [ (dc, all_fields dc) | (dc, _) <- cand_list ])
    se_fix cur
      | sizeOf next == sizeOf cur = cur
      | otherwise                 = se_fix next
      where
        next = listToUFM [ (dc, [ i | i <- lookupWithDefaultUFM cur [] dc, se_ok cur dc i ])
                         | (dc, _) <- cand_list ]
    se_ok m dc i
      =  and [ ctx_ok m ctx | (dc', _, ctx) <- cons_facts, dc' == dc ]
      && and [ case lookup dc cons of
                 Just strs -> fromMaybe False (index i strs)
                 Nothing   -> False
             | (tc, cons) <- case_facts, tc == dataConTyCon dc ]
    ctx_ok _ CDemanded    = True
    ctx_ok _ CAllocated   = False
    ctx_ok m (CField k j) = in_set m k j
    strictly_elim dc i = in_set strictly_eliminated dc i

    arg_fact ev pv a
      | value ev a                      = AValue
      | Var v <- a, Just (dc, i) <- lookupVarEnv pv v = APat dc i
      | otherwise                       = AOther (arg_shape a)

    -- The greatest fixpoint: start from every candidate field, and remove the
    -- fields whose constructions or matches need a removed field boxed
    fixpoint :: UniqFM DataCon [Int] -> UniqFM DataCon [Int]
    fixpoint cur
      | sizeOf next == sizeOf cur = cur
      | otherwise                 = fixpoint next
      where
        next = listToUFM [ (dc, [ i | i <- lookupWithDefaultUFM cur [] dc, ok cur dc i ])
                         | (dc, _) <- cand_list ]
    sizeOf m = sum (map length (nonDetEltsUFM m))
    in_set m dc i = i `elem` lookupWithDefaultUFM m [] dc
    ok m dc i = null (why m dc i)
    why m dc i =
      [ "unsaturated constructor" | (dc', Nothing, _) <- cons_facts, dc' == dc ] ++
      [ "a construction passes a non-value: " ++ arg_why a
        ++ (if strict_everywhere dc i
            then " (every match is strict in it, but it may be built without being eliminated)"
            else "")
      | (dc', Just as, _) <- cons_facts, dc' == dc, Just a <- [index i as], not (arg_ok m a) ] ++
      [ "a match uses it boxed: " ++ use_why u
      | (dc', j, us, _) <- match_facts, dc' == dc, j == i, u <- take 1 (filter (not . use_ok m) us) ]
      where
        arg_ok _ AValue      = True
        arg_ok m' (APat k j) = nested && in_set m' k j   -- Note [Bounding unboxing]
        -- a thunk, if the field is strictly eliminated (Note [Strictly
        -- eliminated fields]); with -fcore-webs-data-unbox-eager, if every
        -- match is strict in it (Note [Eager unboxing])
        arg_ok _ (AOther _)  = strictly_elim dc i || (eager && strict_everywhere dc i)
    strict_everywhere dc i = and [ s | (dc', j, _, s) <- match_facts, dc' == dc, j == i ]
    use_ok _ UScrut        = True
    use_ok _ UStrictArg    = True
    use_ok m (UConArg k j) = nested && in_set m k j   -- Note [Bounding unboxing]
    use_ok _ (UBoxed _)    = False
    index i xs = case drop i xs of { (x : _) -> Just x; [] -> Nothing }

    arg_why (AOther sh)  = sh
    arg_why (APat k _)   = "the pattern variable of a field of " ++ getOccString k ++ " that stays boxed"
    arg_why AValue       = "a value"
    use_why (UBoxed sh)    = sh
    use_why (UConArg k _)  = "stored in a field of " ++ getOccString k ++ " that stays boxed"
    use_why _              = "?"

    -- What a construction passes, when it is not a value
    arg_shape a = case a of
      Var v | Just site <- lookupVarEnv sites v -> site
            | isLocalId v  -> "a variable not known to be evaluated"
            | otherwise    -> "a top-level thunk"
      App {} | (Var f, _) <- collectArgs a -> "a call of " ++ getOccString f
             | otherwise                   -> "an application"
      Case {}   -> "a case"
      Let {}    -> "a let"
      Tick _ e  -> arg_shape e
      Cast e _  -> arg_shape e
      _         -> "something else"

    -- Where each variable is bound (for the dump), and the let-bound variables
    -- whose right-hand side is a value: they are values too (annotation
    -- zaps unfoldings, so exprIsHNF does not see it)
    (sites, let_values) = foldr site_bind (emptyVarEnv, emptyVarSet) binds
      where
        site_bind bind acc = foldr site_pair acc (flattenBinds [bind])
        site_pair (b, rhs) (env, vs)
          | exprIsHNF rhs = site_expr rhs (env, extendVarSet vs b)
          | otherwise     = site_expr rhs (extendVarEnv env b ("a let-bound thunk (" ++ thunk_shape rhs ++ ")"), vs)
        site_expr e acc@(env, vs) = case e of
          Lam b x     -> site_expr x (if isId b then extendVarEnv env b "a function argument" else env, vs)
          App f a     -> site_expr f (site_expr a acc)
          Let bind x  -> site_bind bind (site_expr x acc)
          Case x _ _ as -> site_expr x $ foldr (\(Alt con bs r) a ->
                             site_expr r (case con of
                               DataAlt dc -> (extendVarEnvList (fst a) [ (b', "a field of " ++ getOccString dc) | b' <- bs, isId b' ], snd a)
                               _          -> a)) acc as
          Cast x _    -> site_expr x acc
          Tick _ x    -> site_expr x acc
          _           -> acc
        thunk_shape rhs = case rhs of
          App {} | (Var f, _) <- collectArgs rhs -> "a call of " ++ getOccString f
          Case {} -> "a case"
          Let {}  -> "a let"
          Var _   -> "a variable"
          Tick _ x -> thunk_shape x
          Cast x _ -> thunk_shape x
          _       -> "something else"

    cand_list = [ (dc, [ i | i <- all_fields dc, candidate dc i ])
                | tc <- tcs, dc <- tyConDataCons tc ]
    flat_set = fixpoint (listToUFM cand_list)

    -- Bad (constructor, field) pairs, with why (for the plans and the dump)
    bad :: UniqFM DataCon [(Int, String)]
    bad = listToUFM [ (dc, [ (i, case why flat_set dc i of
                                   (w : _) -> w
                                   []      -> "depends on a field that stays boxed")
                           | i <- all_fields dc, not (in_set flat_set dc i) ])
                    | (dc, _) <- cand_list ]

    -- How a match uses a field's binder b
    usesOf :: Id -> CoreExpr -> [Use]
    usesOf b = go_u
      where
        go_u expr = case expr of
          Var v | v == b    -> [UBoxed "used as a value (returned, bound, or a lazy argument)"]
                | otherwise -> []
          App {}
            | (Var f, args) <- collectArgs expr
            -> let vals = [ a | a <- args, not (isTypeArg a) ]
               in [ UBoxed "called" | f == b ] ++
                  concat [ if is_b a then [classify f j (length vals)] else go_u a
                         | (j, a) <- zip [0 ..] vals ]
          App f a     -> go_u f ++ go_u a
          Lam _ e     -> go_u e
          Let bind e  -> concatMap (go_u . snd) (flattenBinds [bind]) ++ go_u e
          Case (Var v) cb _ alts
            | v == b    -> UScrut : concat [ [ UBoxed "the case binder is used" | cb `elem` exprFreeVarsList r ] ++ go_u r
                                           | Alt _ _ r <- alts ]
          Case e _ _ alts -> go_u e ++ concat [ go_u r | Alt _ _ r <- alts ]
          Cast e _    -> go_u e
          Tick t e    -> [ UBoxed "a breakpoint" | Breakpoint { breakpointFVs = ids } <- [t], b `elem` ids ] ++ go_u e
          _           -> []
        is_b (Var v) = v == b
        is_b _       = False
        -- b as argument j of a call of f with n value arguments
        classify f j n
          | Just dc <- isDataConWorkId_maybe f
          = if n == dataConRepArity dc then UConArg dc j
            else UBoxed ("an argument to an unsaturated " ++ getOccString dc)
          | (ds, _) <- splitDmdSig (idDmdSig f)
          , n >= length ds, Just d <- index j ds, strict_unboxed d
          = UStrictArg
          | (ds, _) <- splitDmdSig (idDmdSig f), n < length ds
          = UBoxed ("an argument to a partial application of " ++ getOccString f)
          | (ds, _) <- splitDmdSig (idDmdSig f), Just (card :* _) <- index j ds, isStrict card
          = UBoxed ("passed to " ++ getOccString f ++ ", which is strict in it but uses it boxed")
          | (ds, _) <- splitDmdSig (idDmdSig f), Just _ <- index j ds
          = UBoxed ("passed to " ++ getOccString f ++ ", which is lazy in it")
          | otherwise
          = UBoxed ("passed to " ++ getOccString f ++ " (no demand signature: imported or unknown)")
        strict_unboxed (card :* sd) = isStrict card && case sd of
          Prod Unboxed _ -> True
          Poly Unboxed _ -> True
          _              -> False

    -- Outer structures first: a split type that is unpacked into another
    -- type's field this round keeps its own fields (its constructor must stay
    -- as it is); flattenFields runs again, and the next round can unbox the
    -- fields the container now holds.
    --
    -- A type whose fields mention a rebuilt type is rebuilt too (all its fields
    -- kept), or its constructors would still mention the old type.  A type
    -- that is unpacked into another cannot be rebuilt (the unpacking uses its
    -- constructor): then that unpacking is dropped, and we try again.
    plans :: Plans
    plans = settle plans0

    settle :: Plans -> Plans
    settle ps
      | null conflicts = with_mentioners
      | otherwise      = settle (drop_unpacking conflicts ps1)
      where
        unpacked = mkUniqSet [ dataConTyCon pdc | (_, cons) <- nonDetUFMToList ps
                                                , (_, fs) <- cons, Flatten pdc _ <- fs ]
        ps1 = filterUFM (any (\(_, fs) -> any is_flat fs)) $
              mapUFM_Directly (\u cons -> if u `elemUniqSet_Directly` unpacked
                                          then [ (dc, map (const Keep) fs) | (dc, fs) <- cons ]
                                          else cons) ps
        rebuilt = close_mentions (nonDetKeysTcs ps1)
        conflicts = [ tc | tc <- rebuilt, tc `elementOfUniqSet` unpacked ]
        with_mentioners = foldr (\tc m -> if tc `elemUFM` m then m
                                          else addToUFM m tc [ (dc, map (const Keep) (all_fields dc))
                                                             | dc <- tyConDataCons tc ])
                                ps1 rebuilt
    nonDetKeysTcs ps = [ tc | tc <- tcs, tc `elemUFM` ps ]
    drop_unpacking bad_tcs ps = filterUFM (any (\(_, fs) -> any is_flat fs)) $
      mapUFM (map (\(dc, fs) -> (dc, [ case f of
                                         Flatten pdc _ | dataConTyCon pdc `elem` bad_tcs -> Keep
                                         _ -> f
                                     | f <- fs ]))) ps
    mentions tc = [ tc' | dc <- tyConDataCons tc, Scaled _ t <- dataConOrigArgTys dc
                        , tc' <- nonDetEltsUniqSet (tyConsOfType t)
                        , tc' `elementOfUniqSet` cands, tc' /= tc ]
    close_mentions start = go_c start
      where go_c acc = let more = [ tc | tc <- tcs, tc `notElem` acc
                                       , any (`elem` acc) (mentions tc) ]
                       in if null more then acc else go_c (acc ++ more)

    plans0 :: Plans
    plans0 = listToUFM
      [ (tc, cons)
      | tc <- tcs
      , let cons = [ (dc, [ plan dc i | i <- all_fields dc ]) | dc <- tyConDataCons tc ]
      , any (\(_, fs) -> any is_flat fs) cons ]
    plan dc i
      | candidate dc i, i `notElem` map fst (lookupWithDefaultUFM bad [] dc)
      , Scaled _ t : _ <- drop i (dataConOrigArgTys dc)
      , Just (_, args, pdc) <- productCon (coreFullView t)
      = Flatten pdc args
      | otherwise = Keep
    value ev a = exprIsHNF a || exprOkForSpeculation a || evald ev a
    evald ev a = case a of
      Var v     -> v `elemVarSet` ev || v `elemVarSet` let_values
      Tick _ e  -> evald ev e
      Cast e _  -> evald ev e
      _         -> False
    is_flat (Flatten {}) = True
    is_flat Keep         = False

    -- The new types: S' with the flattened constructors (same tags)
    news :: UniqFM TyCon (TyCon, UniqFM DataCon DataCon)
    news = listToUFM [ (tc, rebuild u tc cons) | (tc, u) <- zip tcs (listSplitUniqSupply us1)
                                               , Just cons <- [lookupUFM plans tc] ]
    new_tc tc = maybe tc fst (lookupUFM news tc)
    new_con dc = lookupUFM news (dataConTyCon dc) >>= \(_, m) -> lookupUFM m dc
    field_plan dc = lookupUFM plans (dataConTyCon dc) >>= lookup dc

    rebuild u tc cons = (tycon, listToUFM (zip (map fst cons) dcs'))
      where
        (u1, u2) = splitUniqSupply u
        tc_name = setNameUnique (tyConName tc) (uniqFromSupply u1)
        tycon = mkAlgTyCon tc_name (tyConBinders tc) (tyConResKind tc) (tyConRoles tc)
                           Nothing [] (mkDataTyConRhs dcs')
                           (VanillaAlgTyCon (mkPrelTyConRepName tc_name)) False
        self = runIdentity . mapTyCons (== tc) (\_ -> return tycon)
        dcs' = [ mk_con dc fs uc | ((dc, fs), uc) <- zip cons (listSplitUniqSupply u2) ]
        mk_con dc fs uc = dc'
          where
            (u_dc, u_wk) = case uniqsFromSupply uc of
                             (a : b : _) -> (a, b)
                             _           -> panic "flattenFields"
            dc_name = setNameUnique (dataConName dc) u_dc
            wk_name = mkExternalName u_wk this_mod (mkDataConWorkerOcc (getOccName dc)) noSrcSpan
            -- Fields may mention the other types rebuilt this round too
            -- ('ty', lazily: it looks at all of them)
            arg_tys = concat [ case f of
                                 Keep           -> [Scaled m (ty (self t))]
                                 Flatten pdc as -> map (\(Scaled m' t') -> Scaled m' (ty (self t')))
                                                       (dataConInstArgTys pdc as)
                             | (Scaled m t, f) <- zip (dataConOrigArgTys dc) fs ]
            no_bang = HsSrcBang NoSourceText NoSrcUnpack NoSrcStrict
            univs   = dataConUnivTyVars dc
            dc' = mkDataCon dc_name False (mkPrelTyConRepName dc_name)
                    (map (const no_bang) arg_tys) (map (const HsLazy) arg_tys)
                    (map (const NotMarkedStrict) arg_tys)
                    [] univs [] emptyNameEnv (dataConUserTyVarBinders dc) [] []
                    arg_tys (mkTyConApp tycon (mkTyVarTys univs))
                    NoPromInfo tycon (dataConTag dc) [] (mkDataConWorkId wk_name dc') NoDataConRep

    ty :: Type -> Type
    ty = runIdentity . mapTyCons (`elemUFM` news) (return . new_tc)
    -- The rebuilt types have the same parameters: coercions just rename them
    co_rw = runIdentity . mapTyConsCo (`elemUFM` news) (return . new_tc)

    ---------------------------------------------------------------
    rw_bind (NonRec b e) = NonRec (rw_id b) <$> rw e
    rw_bind (Rec prs)    = Rec <$> forM prs (\(b, e) -> (,) (rw_id b) <$> rw e)

    rw_id b | isId b    = setIdType b (ty (idType b))
            | otherwise = b

    rw :: CoreExpr -> UniqSM CoreExpr
    rw expr = case expr of
      Var v
        | Just dc <- isDataConWorkId_maybe v, Just dc' <- new_con dc -> return (Var (dataConWorkId dc'))
        | otherwise -> return (Var (rw_id v))
      Lit {}       -> return expr
      Type t       -> return (Type (ty t))
      Coercion co  -> return (Coercion (co_rw co))
      App {}
        | (Var v, args) <- collectArgs expr
        , Just dc <- isDataConWorkId_maybe v
        , Just dc' <- new_con dc
        , Just fs <- field_plan dc
        -> do { args' <- mapM rw args
              ; let (tys, vals) = span isTypeArg args'
                    ty_args = [ t | Type t <- tys ]
              ; build dc' ty_args fs vals }
      App f a      -> App <$> rw f <*> rw a
      Lam b e      -> Lam (rw_id b) <$> rw e
      Let bind e   -> Let <$> rw_bind bind <*> rw e
      Case e b t alts
        -> do { e' <- rw e
              ; let b' = rw_id b
              ; alts' <- forM alts (rw_alt (idType b'))
              ; return (Case e' b' (ty t) alts') }
      Cast e co    -> (`Cast` co_rw co) <$> rw e
      Tick t e     -> Tick t <$> rw e
      _            -> return expr

    -- K' tys es, taking apart the flattened fields' values
    build dc' ty_args fs vals
      = do { (wrap, vals') <- foldM step (id, []) (zip fs vals)
           ; return (wrap (mkCoreConApps dc' (map Type ty_args ++ reverse vals'))) }
      where
        sub = zipTvSubst (dataConUnivTyVars dc') ty_args
        step (wrap, acc) (Keep, v) = return (wrap, v : acc)
        step (wrap, acc) (Flatten pdc _, v)
          | (Var w, args) <- collectArgs v
          , Just pdc' <- isDataConWorkId_maybe w, pdc' == pdc
          , let vs = [ a | a <- args, not (isTypeArg a) ]
          , length vs == dataConRepArity pdc
          = return (wrap, reverse vs ++ acc)
        step (wrap, acc) (Flatten pdc as, v)
          = do { let comps = map scaledThing (dataConInstArgTys pdc (substTys sub as))
               ; ys <- mapM (fresh "y") comps
               ; b  <- fresh "p" (mkTyConApp (dataConTyCon pdc) (substTys sub as))
               ; let wrap' e = wrap (mkSingleAltCase v b (DataAlt pdc) ys e)
               ; return (wrap', reverse (map Var ys) ++ acc) }

    -- An alternative: bind the components, and replace the cases on the field
    rw_alt scrut_ty (Alt (DataAlt dc) bs rhs)
      | Just dc' <- new_con dc, Just fs <- field_plan dc
      = do { rhs' <- rw rhs
           ; let ty_args = fromMaybe [] (tyConAppArgs_maybe scrut_ty)
                 sub = zipTvSubst (dataConUnivTyVars dc') ty_args
           ; (bs', body) <- foldM (field sub) ([], rhs') (zip fs (map rw_id bs))
           ; return (Alt (DataAlt dc') (reverse bs') body) }
    rw_alt _ (Alt con bs rhs) = Alt con (map rw_id bs) <$> rw rhs

    field _ (acc, body) (Keep, b) = return (b : acc, body)
    field sub (acc, body) (Flatten pdc as, b)
      = do { let comps = map scaledThing (dataConInstArgTys pdc (substTys sub as))
           ; ys <- mapM (fresh "y") comps
           ; let body1 = replaceCases b pdc ys body
                 body2 | b `elemVarSet'` body1
                       = Let (NonRec b (mkCoreConApps pdc (map Type (substTys sub as) ++ map Var ys))) body1
                       | otherwise = body1
           ; return (reverse ys ++ acc, body2) }

    elemVarSet' b e = b `elementOfUniqSet` exprFreeIdsSet e
    exprFreeIdsSet e = mkUniqSet (freeIds e)
    freeIds e = case e of
      Var v -> [v]
      App f a -> freeIds f ++ freeIds a
      Lam _ x -> freeIds x
      Let bind x -> concatMap (freeIds . snd) (flattenBinds [bind]) ++ freeIds x
      Case s _ _ as -> freeIds s ++ concat [ freeIds r | Alt _ _ r <- as ]
      Cast x _ -> freeIds x
      Tick _ x -> freeIds x
      _ -> []

    fresh fs t = do { u <- getUniqueM; return (mkSysLocal (fsLit fs) u ManyTy t) }

    dump = vcat [ ppr dc <+> text "field" <+> int i <> colon <+> verdict
                | tc <- tcs, dc <- tyConDataCons tc, i <- all_fields dc, candidate dc i
                , let verdict
                        | Just fs <- field_plan dc, Flatten {} : _ <- drop i fs = text "unboxed"
                        | (why : _) <- [ w | (j, w) <- lookupWithDefaultUFM bad [] dc, j == i ]
                        = text "boxed" <+> parens (text why)
                        | otherwise = text "boxed (its type is unpacked into another this round)" ]
