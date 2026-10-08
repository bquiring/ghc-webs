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
import GHC.Types.Demand ( Demand(..), SubDemand(..), splitDmdSig, isStrict, isStrUsedDmd )
import GHC.Types.Tickish ( GenTickish(..) )
import GHC.Core.FVs ( exprFreeVarsList )

import GHC.Unit.Module ( Module )
import GHC.Utils.Outputable
import GHC.Utils.Panic ( panic )

import GHC.WebCore.DataSplit ( mapTyCons, mapTyConsCo )
import GHC.WebCore.Transform.ArityRaise ( productCon, replaceCases )

import Control.Monad ( forM, foldM )
import Data.Functor.Identity ( runIdentity )
import Data.Maybe ( isNothing, fromMaybe )

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
         | AOther

-- | A use of a field's pattern variable in a match
data Use = UScrut              -- ^ the scrutinee of a case
         | UStrictArg          -- ^ an argument a callee is strict in and unboxes
         | UConArg DataCon Int -- ^ an argument to another candidate field
         | UBoxed

-- | What happens to a field
data Field = Keep | Flatten DataCon [Type]   -- ^ P's constructor and type arguments

-- | Per split type: its constructors' field plans (by tag), if any is flattened
type Plans = UniqFM TyCon [(DataCon, [Field])]

flattenFields :: Bool -> Module -> UniqSupply -> [TyCon] -> CoreProgram
              -> (CoreProgram, [TyCon], SDoc)
flattenFields eager this_mod us tcs binds
  | isNullUFM plans = (binds, tcs, dump)
  | otherwise       = (initUs_ us2 (mapM rw_bind binds), map new_tc tcs, dump)
  where
    (us1, us2) = splitUniqSupply us
    cands = mkUniqSet tcs
    _ = cands

    -- Candidate fields: products, not recursive
    candidate :: DataCon -> Int -> Bool
    candidate dc i = case drop i (dataConOrigArgTys dc) of
      (Scaled _ t : _)
        | Just (ptc, _, pdc) <- productCon (coreFullView t)
        , ptc /= dataConTyCon dc
        , isNothing (dataConWrapId_maybe pdc)
        , all (typeHasFixedRuntimeRep . scaledThing) (dataConOrigArgTys pdc)
        -> True
      _ -> False

    -- Facts (Note [Unboxable fields]): what each construction passes in each
    -- field, and how each match uses each field
    cons_facts  :: [(DataCon, Maybe [ArgFact])]      -- Nothing: unsaturated
    match_facts :: [(DataCon, Int, [Use], Bool)]    -- Bool: the match is strict in it
    (cons_facts, match_facts) = foldr (go_bind emptyVarSet emptyVarEnv) ([], []) binds

    is_cand_con dc = dataConTyCon dc `elementOfUniqSet` cands
    all_fields dc = [0 .. dataConRepArity dc - 1]

    go_bind ev pv bind acc = foldr (\(_, e) -> go ev pv e) acc (flattenBinds [bind])

    -- ev: variables known to be evaluated (case binders);
    -- pv: pattern variables of candidate constructors' fields
    go ev pv expr acc@(cf, mf) = case expr of
      App {}
        | (Var v, args) <- collectArgs expr
        , Just dc <- isDataConWorkId_maybe v, is_cand_con dc
        -> let vals = [ a | a <- args, not (isTypeArg a) ]
               acc' = foldr (go ev pv) acc args
               fact | length vals == dataConRepArity dc = Just (map (arg_fact ev pv) vals)
                    | otherwise                          = Nothing
           in (\(c, m) -> ((dc, fact) : c, m)) acc'
      Var v
        | Just dc <- isDataConWorkId_maybe v, is_cand_con dc
        , dataConRepArity dc > 0
        -> ((dc, Nothing) : cf, mf)
      App f a     -> go ev pv f (go ev pv a acc)
      Lam _ e     -> go ev pv e acc
      Let bind e  -> go_bind ev pv bind (go ev pv e acc)
      Case e b _ alts
        -> let ev' = extendVarSet ev b
           in go ev pv e $
              foldr (\(Alt con bs rhs) a -> alt ev' pv con bs rhs a) acc alts
      Cast e _    -> go ev pv e acc
      Tick _ e    -> go ev pv e acc
      _           -> acc

    alt ev pv (DataAlt dc) bs rhs acc
      | is_cand_con dc
      = let fbs = filter isId bs
            pv' = extendVarEnvList pv [ (b, (dc, i)) | (i, b) <- zip [0 ..] fbs ]
            (cf, mf) = go ev pv' rhs acc
        in (cf, [ (dc, i, usesOf b rhs, isStrUsedDmd (idDemandInfo b))
                | (i, b) <- zip [0 ..] fbs, candidate dc i ] ++ mf)
    alt ev pv _ _ rhs acc = go ev pv rhs acc

    arg_fact ev pv a
      | value ev a                      = AValue
      | Var v <- a, Just (dc, i) <- lookupVarEnv pv v = APat dc i
      | otherwise                       = AOther

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
      [ "unsaturated constructor" | (dc', Nothing) <- cons_facts, dc' == dc ] ++
      [ "a construction passes a non-value"
      | (dc', Just as) <- cons_facts, dc' == dc, Just a <- [index i as], not (arg_ok m a) ] ++
      [ "a match uses it boxed"
      | (dc', j, us, _) <- match_facts, dc' == dc, j == i, not (all (use_ok m) us) ]
      where
        arg_ok _ AValue      = True
        arg_ok m' (APat k j) = in_set m' k j
        -- -fcore-webs-data-unbox-eager: a thunk too, if every match is
        -- strict in the field (Note [Eager unboxing])
        arg_ok _ AOther      = eager && strict_everywhere dc i
    strict_everywhere dc i = and [ s | (dc', j, _, s) <- match_facts, dc' == dc, j == i ]
    use_ok _ UScrut        = True
    use_ok _ UStrictArg    = True
    use_ok m (UConArg k j) = in_set m k j
    use_ok _ UBoxed        = False
    index i xs = case drop i xs of { (x : _) -> Just x; [] -> Nothing }

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
          Var v | v == b    -> [UBoxed]
                | otherwise -> []
          App {}
            | (Var f, args) <- collectArgs expr
            -> let vals = [ a | a <- args, not (isTypeArg a) ]
               in [ UBoxed | f == b ] ++
                  concat [ if is_b a then [classify f j (length vals)] else go_u a
                         | (j, a) <- zip [0 ..] vals ]
          App f a     -> go_u f ++ go_u a
          Lam _ e     -> go_u e
          Let bind e  -> concatMap (go_u . snd) (flattenBinds [bind]) ++ go_u e
          Case (Var v) cb _ alts
            | v == b    -> UScrut : concat [ [ UBoxed | cb `elem` exprFreeVarsList r ] ++ go_u r
                                           | Alt _ _ r <- alts ]
          Case e _ _ alts -> go_u e ++ concat [ go_u r | Alt _ _ r <- alts ]
          Cast e _    -> go_u e
          Tick t e    -> [ UBoxed | Breakpoint { breakpointFVs = ids } <- [t], b `elem` ids ] ++ go_u e
          _           -> []
        is_b (Var v) = v == b
        is_b _       = False
        -- b as argument j of a call of f with n value arguments
        classify f j n
          | Just dc <- isDataConWorkId_maybe f
          = if n == dataConRepArity dc then UConArg dc j else UBoxed
          | (ds, _) <- splitDmdSig (idDmdSig f)
          , n >= length ds, Just d <- index j ds, strict_unboxed d
          = UStrictArg
          | otherwise = UBoxed
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
      Var v     -> v `elemVarSet` ev
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
