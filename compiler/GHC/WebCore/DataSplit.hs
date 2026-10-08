-- | Splitting data types by data flow: each class of occurrences of a data
-- type that never meets the outside world gets its own copy of the type.
--
-- See Note [Splitting data types].
module GHC.WebCore.DataSplit
  ( DataSplitResult(..)
  , splitDataTypes
  , mapTyCons
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.DataCon
import GHC.Core.FVs ( rulesFreeVars, idRuleVars, idUnfoldingVars )
import GHC.Core.Multiplicity ( Scaled(..) )
import GHC.Core.TyCo.Rep
import GHC.Core.TyCon
import GHC.Core.Type

import GHC.Data.Bag

import GHC.Types.Id
import GHC.Types.Id.Make ( mkDataConWorkId )
import GHC.Types.Name
import GHC.Types.Name.Env ( emptyNameEnv )
import GHC.Types.SourceText ( SourceText(..) )
import GHC.Types.SrcLoc ( noSrcSpan )
import GHC.Types.Tickish
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Unique ( Unique, getKey, getUnique )
import GHC.Types.Unique.Supply
import GHC.Types.Var.Env
import GHC.Types.Var.Set

import GHC.Unit.Module ( Module )

import GHC.Utils.Outputable
import GHC.Utils.Panic ( panic, pprPanic )

import GHC.WebCore.DataCopy
import GHC.WebCore.DataLint ( LintConfig, DataLintResult(..), lintDataProgram )
import {-# SOURCE #-} GHC.WebCore.DataFlatten ( flattenFields )

import Control.Monad ( forM )
import Control.Monad.Trans.State.Strict
import Data.Char ( isUpper )
import Data.List ( sortOn, nub )
import Data.Maybe ( isNothing, catMaybes, fromMaybe )

{- Note [Splitting data types]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
With -fcore-webs-data-split, the early web run first splits data types.  Two
lists that never meet -- directly, or through a function, a constructor or a
case -- could have different types.  A class of occurrences of a data type T
that never meets code compiled without this analysis (an imported function,
an exported binder, a coercion) gets its own copy of T, a new local type.
On its own this changes nothing at run time; it is what lets later passes
change one copy's representation (strict, unpacked or dead fields) without
touching the others (WEBS-DATA.md, phases 2 and 3).

Data types carry no webs.  Instead we use copies:

  1. Annotation.  Every occurrence of an eligible T -- in the type of a
     binder, a type argument, a case's type, and every constructor worker --
     gets a fresh copy of T: a TyCon of its own, with its own DataCons.  In
     a copy's constructors, every occurrence of T itself (the recursive
     fields) is that copy: a list's tail is the same copy as the list.
     Other data types in fields stay as they are (so what flows through them
     is exposed).  A case alternative uses the constructor of the case
     binder's copy.

  2. Data Lint (GHC.WebCore.DataLint), a copy of Core Lint, type-checks the
     annotated program up to copies, and records a pair of type constructors
     wherever it requires two types to be equal and they have different
     copies (or a copy and the original) at the same place.

  3. Union-find over the pairs gives classes of copies.  A class that
     contains an original type constructor is exposed: it meets code that
     expects T.

  4. Each non-exposed class gets a new type T_s<n>, with only the
     constructors that the class builds: a constructor that no occurrence in
     the class builds can never be scrutinised, so its case alternatives in
     the class are dropped.  A class that builds nothing holds only bottom,
     and goes back to T, as does every exposed class.  Rewriting every copy
     to its class's type gives the result, which Core Lint checks as usual.

Not touched (their occurrences keep T, so whatever reaches them is exposed):
binders that are exported, have stable unfoldings or rules, or are mentioned
by those or by the module's rules ('pinned'); coercions; type and data
family applications; kinds.

Eligible types: algebraic data types with at least one constructor and some
field, not newtypes, classes, unboxed tuples or sums, family instances, or
enumerations; every constructor vanilla (no existentials or equalities),
with no wrapper (so no strict or unpacked fields, for now); kinds closed.
-}

-- | The result of splitting
data DataSplitResult = DataSplitResult
  { dsr_binds   :: CoreProgram        -- ^ the new program
  , dsr_tycons  :: [TyCon]            -- ^ the new types
  , dsr_dump    :: SDoc               -- ^ for -ddump-webs-data
  , dsr_lint    :: DataLintResult     -- ^ Data Lint on the annotated program
  , dsr_changed :: Bool }

------------------------------------------------------------------
--      Eligibility
------------------------------------------------------------------

eligible :: TyCon -> Bool
eligible tc
  =  isAlgTyCon tc && isDataTyCon tc
  && not (isUnboxedTupleTyCon tc) && not (isUnboxedSumTyCon tc)
  && not (isClassTyCon tc) && not (isFamInstTyCon tc) && not (isTypeDataTyCon tc)
  && not (isEnumerationTyCon tc)
  && not (null dcs) && any (not . null . dataConOrigArgTys) dcs
  && all ok_dc dcs
  && all ok_binder (tyConBinders tc)
  where
    dcs = tyConDataCons tc
    ok_dc dc = isVanillaDataCon dc && null (dataConTheta dc)
               && isNothing (dataConWrapId_maybe dc)
    ok_binder b = not (isNamedTyConBinder b) && noFreeVarsOfType (tyVarKind (binderVar b))

------------------------------------------------------------------
--      Copies
------------------------------------------------------------------

-- | A copy of a data type with some of its constructors (by tag, in order).
-- Every occurrence of the type in the constructors' fields is the copy.
mkCopy :: UniqSupply -> (Unique -> OccName -> Name) -> OccName -> (DataCon -> Int -> OccName)
       -> TyCon -> [DataCon] -> TyCon
mkCopy us mk_name tc_occ dc_occ tc dcs = tycon
  where
    (us1, us2) = splitUniqSupply us
    tc_name = mk_name (uniqFromSupply us1) tc_occ
    tycon   = mkAlgTyCon tc_name (tyConBinders tc) (tyConResKind tc) (tyConRoles tc)
                         Nothing [] (mkDataTyConRhs cons)
                         (VanillaAlgTyCon (mkPrelTyConRepName tc_name)) False
    cons    = [ mk_con tag dc u | (tag, dc, u) <- zip3 [1 ..] dcs (listSplitUniqSupply us2) ]

    self ty = case ty of
      TyConApp tc' tys
        | tc' == tc   -> TyConApp tycon (map self tys)
        | otherwise   -> TyConApp tc' (map self tys)
      FunTy { ft_arg = a, ft_res = r } -> ty { ft_arg = self a, ft_res = self r }
      AppTy t1 t2  -> AppTy (self t1) (self t2)
      ForAllTy b t -> ForAllTy b (self t)
      CastTy t co  -> CastTy (self t) co
      _            -> ty

    mk_con tag dc u = dc'
      where
        (u_dc, u_wk) = case uniqsFromSupply u of
                         (a : b : _) -> (a, b)
                         _           -> panic "mkCopy"
        occ     = dc_occ dc tag
        dc_name = mk_name u_dc occ
        wk_name = mk_name u_wk (mkDataConWorkerOcc occ)
        arg_tys = [ Scaled m (self t) | Scaled m t <- dataConOrigArgTys dc ]
        no_bang = HsSrcBang NoSourceText NoSrcUnpack NoSrcStrict
        univs   = dataConUnivTyVars dc
        dc' = mkDataCon dc_name False (mkPrelTyConRepName dc_name)
                (map (const no_bang) arg_tys) (map (const HsLazy) arg_tys)
                (map (const NotMarkedStrict) arg_tys)
                [] univs [] emptyNameEnv (dataConUserTyVarBinders dc) [] []
                arg_tys (mkTyConApp tycon (mkTyVarTys univs))
                NoPromInfo tycon tag [] (mkDataConWorkId wk_name dc') NoDataConRep

-- | A constructor of a type with a given original tag
conWithTag :: TyCon -> Int -> Maybe DataCon
conWithTag tc tag = case [ dc | dc <- tyConDataCons tc, dataConTag dc == tag ] of
  (dc : _) -> Just dc
  []       -> Nothing

------------------------------------------------------------------
--      Traversal
------------------------------------------------------------------

-- | How to rewrite a program: types, binders, constructor occurrences, and
-- case alternatives (given the new case binder; Nothing drops it)
data Mapper m = Mapper
  { m_ty   :: Type -> m Type
  , m_bndr :: Id -> m Id
  , m_con  :: DataCon -> m Id
  , m_alt  :: Id -> DataCon -> m (Maybe DataCon) }

mapProgram :: forall m. Monad m => Mapper m -> CoreProgram -> m CoreProgram
mapProgram mp binds
  = do { tops <- mapM (m_bndr mp) top_bs
       ; let env0 = mkVarEnv (zip top_bs tops)
       ; mapM (top env0) binds }
  where
    top_bs = bindersOfBinds binds

    lk env v = lookupVarEnv env v `orElse'` v
    orElse' (Just x) _ = x
    orElse' Nothing y  = y

    top env (NonRec b e) = NonRec (lk env b) <$> go env e
    top env (Rec prs)    = Rec <$> mapM (\(b, e) -> (,) (lk env b) <$> go env e) prs

    bndr env b
      | isId b    = do { b' <- m_bndr mp b; return (extendVarEnv env b b', b') }
      | otherwise = return (env, b)
    bndrs env [] = return (env, [])
    bndrs env (b : bs) = do { (env1, b') <- bndr env b; (env2, bs') <- bndrs env1 bs
                            ; return (env2, b' : bs') }

    go :: VarEnv Id -> CoreExpr -> m CoreExpr
    go env expr = case expr of
      Var v
        | Just dc <- isDataConWorkId_maybe v -> Var <$> m_con mp dc
        | otherwise                          -> return (Var (lk env v))
      Lit {}      -> return expr
      Type t      -> Type <$> m_ty mp t
      Coercion {} -> return expr
      App f a     -> App <$> go env f <*> go env a
      Lam b e     -> do { (env', b') <- bndr env b; Lam b' <$> go env' e }
      Let (NonRec b rhs) body
        -> do { rhs' <- go env rhs; (env', b') <- bndr env b
              ; Let (NonRec b' rhs') <$> go env' body }
      Let (Rec prs) body
        -> do { (env', bs') <- bndrs env (map fst prs)
              ; rhss <- mapM (go env' . snd) prs
              ; Let (Rec (zip bs' rhss)) <$> go env' body }
      Case scrut b ty alts
        -> do { scrut' <- go env scrut
              ; (env', b') <- bndr env b
              ; ty' <- m_ty mp ty
              ; alts' <- forM alts $ \(Alt con bs rhs) ->
                  do { mb_con <- case con of
                         DataAlt dc -> fmap DataAlt <$> m_alt mp b' dc
                         _          -> return (Just con)
                     ; case mb_con of
                         Nothing   -> return Nothing
                         Just con' -> do { (env'', bs') <- bndrs env' bs
                                         ; Just . Alt con' bs' <$> go env'' rhs } }
              ; return (Case scrut' b' ty' (catMaybes alts')) }
      Cast e co   -> (\e' -> Cast e' co) <$> go env e
      Tick t e    -> Tick (tick env t) <$> go env e
      WebLam {}   -> panic "DataSplit: web form"
      WebApp {}   -> panic "DataSplit: web form"

    tick env t@(Breakpoint { breakpointFVs = ids }) = t { breakpointFVs = map (lk env) ids }
    tick _ t = t

-- | Map the type constructors of a type (through synonyms that hide one)
mapTyCons :: Monad m => (TyCon -> Bool) -> (TyCon -> m TyCon) -> Type -> m Type
mapTyCons want f = go
  where
    go ty = case ty of
      TyConApp tc tys
        | isTypeSynonymTyCon tc, Just ty' <- coreView ty, mentions ty' -> go ty'
        | isFamilyTyCon tc -> return ty
        | want tc   -> TyConApp <$> f tc <*> mapM go tys
        | otherwise -> TyConApp tc <$> mapM go tys
      FunTy { ft_arg = a, ft_res = r } -> (\a' r' -> ty { ft_arg = a', ft_res = r' }) <$> go a <*> go r
      AppTy t1 t2  -> AppTy <$> go t1 <*> go t2
      ForAllTy b t -> ForAllTy b <$> go t
      CastTy t co  -> (\t' -> CastTy t' co) <$> go t
      _            -> return ty
    mentions t = any want (nonDetEltsUniqSet (tyConsOfType t))

------------------------------------------------------------------
--      Annotation
------------------------------------------------------------------

data AnnState = AnnState
  { as_mod     :: Module
  , as_us      :: UniqSupply
  , as_copies  :: Copies
  , as_all     :: [TyCon]           -- ^ every copy
  , as_built   :: [(TyCon, Int)]    -- ^ copy, tag of a constructor built there
  , as_matched :: [(TyCon, Int)] }  -- ^ copy, tag of a constructor matched there

type AnnM = State AnnState

newCopy :: TyCon -> AnnM TyCon
newCopy tc = do
  { s <- get
  ; let (us1, us2) = splitUniqSupply (as_us s)
        c = mkCopy us1 (\u occ -> mkExternalName u (as_mod s) occ noSrcSpan) (getOccName tc)
                   (\dc _ -> getOccName dc) tc (tyConDataCons tc)
  ; put s { as_us = us2, as_copies = addToUFM (as_copies s) c tc, as_all = c : as_all s }
  ; return c }

annMapper :: VarSet -> Mapper AnnM
annMapper pinned = Mapper
  { m_ty   = ann_ty
  , m_bndr = \b -> if b `elemVarSet` pinned then return (zap b)
                   else do { t <- ann_ty (idType b); return (zap (setIdType b t)) }
  , m_con  = \dc -> if eligible (dataConTyCon dc)
                    then do { c <- newCopy (dataConTyCon dc)
                            ; modify (\s -> s { as_built = (c, dataConTag dc) : as_built s })
                            ; return (dataConWorkId (con c dc)) }
                    else return (dataConWorkId dc)
  , m_alt  = \b dc -> case splitTyConApp_maybe (idType b) of
      Just (c, _) | c /= dataConTyCon dc, eligible (dataConTyCon dc)
        -> do { modify (\s -> s { as_matched = (c, dataConTag dc) : as_matched s })
              ; return (Just (con c dc)) }
      _ -> return (Just dc) }
  where
    ann_ty = mapTyCons eligible newCopy
    con c dc = fromMaybe (pprPanic "DataSplit: constructor" (ppr dc)) (conWithTag c (dataConTag dc))
    -- Vanilla unfoldings may mention binders whose types change; the
    -- simplifier rebuilds them
    zap b | isStableUnfolding (realIdUnfolding b) = b
          | otherwise                             = zapIdUnfolding b

-- | Binders whose types stay: exported, with stable unfoldings or rules,
-- and whatever those or the module's rules mention
pinnedIds :: [CoreRule] -> CoreProgram -> VarSet
pinnedIds rules binds = close seeds seeds
  where
    all_bs = concatMap bndrs binds
    bndrs (NonRec b e) = b : expr_bs e
    bndrs (Rec prs)    = concatMap (\(b, e) -> b : expr_bs e) prs
    expr_bs e = case e of
      Lam b x      -> b : expr_bs x
      App f a      -> expr_bs f ++ expr_bs a
      Let bind x   -> bndrs bind ++ expr_bs x
      Case s b _ as -> b : expr_bs s ++ concat [ bs ++ expr_bs r | Alt _ bs r <- as ]
      Cast x _     -> expr_bs x
      Tick _ x     -> expr_bs x
      _            -> []

    seeds = mkVarSet [ b | b <- all_bs, isId b
                         , isExportedId b || isStableUnfolding (realIdUnfolding b)
                           || not (isEmptyVarSet (idRuleVars b))
                           || not (null (idCoreRules b)) ]
            `unionVarSet` filterVarSet isLocalId (rulesFreeVars rules)

    mentioned v = filterVarSet isLocalId (idRuleVars v `unionVarSet` idUnfoldingVars v)

    close acc new
      | isEmptyVarSet new = acc
      | otherwise = let more = foldr (unionVarSet . mentioned) emptyVarSet (nonDetEltsUniqSet new)
                        new' = more `minusVarSet` acc
                    in close (acc `unionVarSet` new') new'

------------------------------------------------------------------
--      Solving
------------------------------------------------------------------

-- | Connected components of the pairs: each type constructor to a
-- representative
components :: [TyCon] -> Bag (TyCon, TyCon) -> UniqFM TyCon TyCon
components nodes pairs = foldl visit emptyUFM all_nodes
  where
    adj :: UniqFM TyCon [TyCon]
    adj = foldl (\m (a, b) -> addToUFM_C (++) (addToUFM_C (++) m a [b]) b [a]) emptyUFM
                (bagToList pairs)
    all_nodes = nodes ++ concat [ [a, b] | (a, b) <- bagToList pairs ]
    visit acc n
      | n `elemUFM` acc = acc
      | otherwise       = dfs n acc [n]
    dfs _ acc [] = acc
    dfs rep acc (x : xs)
      | x `elemUFM` acc = dfs rep acc xs
      | otherwise = dfs rep (addToUFM acc x rep) (lookupWithDefaultUFM adj [] x ++ xs)

------------------------------------------------------------------
--      The pass
------------------------------------------------------------------

-- | What a class of copies becomes: the original, or a new type with the
-- constructors the class builds (by original tag)
data Fate = Exposed | Bottom | Split TyCon [(Int, DataCon)]

splitDataTypes :: Bool -> LintConfig -> Module -> UniqSupply -> [CoreRule] -> CoreProgram
               -> DataSplitResult
splitDataTypes unbox cfg this_mod us rules binds
  = DataSplitResult
      { dsr_binds   = final_binds
      , dsr_tycons  = final_tcs
      , dsr_dump    = dump $$ flat_dump
      , dsr_lint    = lint_res
      , dsr_changed = changed }
  where
    (us1, us23) = splitUniqSupply us
    (us2, us3)  = splitUniqSupply us23
    split_binds = evalState (mapProgram rwMapper ann_binds) ()
    -- Unbox fields of the new types (Note [Flattening fields] in
    -- GHC.WebCore.DataFlatten)
    (final_binds, final_tcs, flat_dump)
      | not changed = (binds, [], empty)
      | unbox       = flattenFields this_mod us3 new_tcs split_binds
      | otherwise   = (split_binds, new_tcs, empty)
    pinned = pinnedIds rules binds
    (ann_binds, st) = runState (mapProgram (annMapper pinned) binds)
                               (AnnState this_mod us1 emptyUFM [] [] [])
    copies   = as_copies st
    lint_res = lintDataProgram cfg copies ann_binds
    ok       = isEmptyBag (dlr_errs lint_res)
    pairs    = bagToList (dlr_pairs lint_res)
    is_copy c = c `elemUFM` copies

    -- Classes: representative -> members
    rep_of = components (as_all st) (dlr_pairs lint_res)
    rep c  = lookupWithDefaultUFM rep_of c c
    members :: UniqFM TyCon [TyCon]
    members = foldl (\m c -> addToUFM_C (++) m (rep c) [c]) emptyUFM
                    (nubTc (as_all st ++ concat [ [a, b] | (a, b) <- pairs ]))
    nubTc = nonDetEltsUniqSet . mkUniqSet

    built   = foldl (\m (c, t) -> addToUFM_C (++) m (rep c) [t]) emptyUFM (as_built st)
    matched = foldl (\m (c, t) -> addToUFM_C (++) m (rep c) [t]) emptyUFM (as_matched st)

    -- The classes, in a deterministic order (by their first copy)
    classes = map snd $ sortOn fst
                [ (foldl' min (getKey (getUnique m0)) (map (getKey . getUnique) ms)
                  , ( copyOriginal copies r, ms
                    , sortOn id (nub (lookupWithDefaultUFM built [] r))
                    , sortOn id (nub (lookupWithDefaultUFM matched [] r)) ))
                | ms@(m0 : _) <- nonDetEltsUFM members, let r = rep m0 ]
    fates :: [([TyCon], TyCon, Fate, [Int], [Int])]    -- members, original, fate, built, matched
    fates = [ (ms, orig, fate, bs, mts)
            | (n, (orig, ms, bs, mts)) <- zip [1 :: Int ..] classes
            , let fate | any (not . is_copy) ms = Exposed
                       | null bs                = Bottom
                       | otherwise              = mk_split n orig bs ]

    split_us = listSplitUniqSupply us2
    mk_split n orig tags = Split tc (zip tags (tyConDataCons tc))
      where
        tc = mkCopy (split_us !! n)
                    (\u occ -> mkExternalName u this_mod occ noSrcSpan)
                    (mkTcOcc (occNameString (getOccName orig) ++ "_s" ++ show n))
                    (\dc _ -> mkDataOcc (con_base dc ++ "_s" ++ show n))
                    orig [ dc | dc <- tyConDataCons orig, dataConTag dc `elem` tags ]
    -- Constructors with alphanumeric names keep them; [], (:) and tuples
    -- become Con<tag>
    con_base dc = case occNameString (getOccName dc) of
      str@(c : _) | isUpper c -> str
      _                       -> "Con" ++ show (dataConTag dc)

    fate_of :: UniqFM TyCon Fate      -- every member of a class
    fate_of = listToUFM [ (m, f) | (ms, _, f, _, _) <- fates, m <- ms ]

    new_tcs = [ tc | (_, _, Split tc _, _, _) <- fates ]
    changed = ok && not (null new_tcs)

    -- The type constructor a copy becomes, and a constructor (by original tag)
    final c = case lookupUFM fate_of c of
      Just (Split tc _) -> tc
      _                 -> copyOriginal copies c
    final_con c tag = case lookupUFM fate_of c of
      Just (Split _ cons) -> lookup tag cons
      _                   -> conWithTag (copyOriginal copies c) tag

    rwMapper :: Mapper (State ())
    rwMapper = Mapper
      { m_ty   = rw_ty
      , m_bndr = \b -> do { t <- rw_ty (idType b); return (setIdType b t) }
      , m_con  = \dc -> let tc = dataConTyCon dc in
                        if is_copy tc
                        then case final_con tc (dataConTag dc) of
                               Just dc' -> return (dataConWorkId dc')
                               Nothing  -> pprPanic "DataSplit: built constructor" (ppr dc)
                        else return (dataConWorkId dc)
      , m_alt  = \_ dc -> let tc = dataConTyCon dc in
                          if is_copy tc then return (final_con tc (dataConTag dc))
                          else return (Just dc) }
    rw_ty = mapTyCons is_copy (return . final)

    dump = vcat
      [ text "Data Lint:" <+> (if ok then text "ok" else text "errors (not split)")
      , text "copies:" <+> int (sizeUFM copies) <> comma
        <+> text "classes:" <+> int (length fates) <> comma
        <+> text "exposed:" <+> int (length [ () | (_, _, Exposed, _, _) <- fates ]) <> comma
        <+> text "split:" <+> int (length new_tcs) <> comma
        <+> text "pinned binders:" <+> int (sizeVarSet pinned)
      , vcat [ ppr tc <+> text "=" <+> ppr orig
               <+> text "with" <+> hsep (punctuate comma (map ppr (tyConDataCons tc)))
               <+> parens (text "built" <+> ppr bs <> comma <+> text "matched" <+> ppr ms
                           <> (if length bs < length (tyConDataCons orig)
                               then comma <+> text "dropped" <+> ppr [ dataConTag dc | dc <- tyConDataCons orig
                                                                    , dataConTag dc `notElem` bs ]
                               else empty))
             | (_, orig, Split tc _, bs, ms) <- fates ] ]
