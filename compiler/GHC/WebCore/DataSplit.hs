-- | Splitting data types by data flow: each class of occurrences of a data
-- type that never meets the outside world gets its own copy of the type.
--
-- See Note [Splitting data types].
module GHC.WebCore.DataSplit
  ( DataSplitResult(..)
  , PairSource(..)
  , splitDataTypes
  , mapTyCons
  , mapTyConsCo
  , nonParametric
  ) where

import GHC.Prelude
import Data.List ( isPrefixOf )

import GHC.Core
import GHC.Core.DataCon
import GHC.Core.FVs ( rulesFreeVars, idRuleVars, idUnfoldingVars )
import GHC.Core.SimpleOpt ( simpleOptExpr, defaultSimpleOpts )
import GHC.Core.Multiplicity ( Scaled(..), scaledThing )
import GHC.Core.TyCo.Rep
import GHC.Core.TyCon
import GHC.Core.Type
import GHC.Core.Coercion ( coercionLKind, coercionKind, isCoVar )
import GHC.Data.Pair ( Pair(..) )
import GHC.Core.Coercion.Axiom ( CoAxiomRule(..), coAxiomTyCon )
import GHC.Core.FamInstEnv ( mkNewTypeCoAxiom )
import Data.Functor.Identity ( runIdentity )
import GHC.Core.Utils ( exprType )
import GHC.Core.Seq ( seqBinds )

import GHC.Data.Bag

import GHC.Types.Id
import GHC.Builtin.PrimOps ( PrimOp(AtomicModifyMutVar2Op) )
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

import GHC.Unit.Module ( Module, moduleName, moduleNameString )

import GHC.Utils.Outputable
import GHC.Utils.Panic ( panic, pprPanic )

import GHC.WebCore.DataCopy
import GHC.WebCore.DataLint ( LintConfig, DataLintResult(..), lintDataProgram )
import GHC.WebCore.DataInfer ( inferCopyPairs, solveCopies )
import {-# SOURCE #-} GHC.WebCore.DataFlatten ( flattenFields )
import GHC.WebCore.DataSpec ( specialiseSplit )

import Control.Monad ( forM )
import Control.Monad.Trans.State.Strict
import Data.Char ( isUpper, isDigit )
import Data.List ( sortOn, nub )
import Data.Maybe ( isNothing, isJust, catMaybes, fromMaybe )
import qualified Data.Set as Set
import qualified Data.IntSet as IntSet
import GHC.WebCore.Transform.ArityRaise ( productCon )

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

  2. Pairs: wherever the program requires two types to be equal and they
     have different copies (or a copy and the original) at the same place,
     the two type constructors are paired.  A walk of the program finds them
     by unification (Note [Inferring copy pairs] in GHC.WebCore.DataInfer).
     With -fcore-webs-data-lint-pairs, Data Lint (GHC.WebCore.DataLint, a
     copy of Core Lint) records them instead, while type-checking the
     annotated program up to copies.

  3. The classes of copies are the components of the pairs, closed under
     congruence for newtype copies (Note [Solving copy classes online] in
     GHC.WebCore.DataInfer).  A class that contains an original type
     constructor is exposed: it meets code that expects T.

  4. Each non-exposed class gets a new type T_s<n>, with only the
     constructors that the class builds: a constructor that no occurrence in
     the class builds can never be scrutinised, so its case alternatives in
     the class are dropped.  A class that builds nothing holds only bottom,
     and goes back to T, as does every exposed class.  Rewriting every copy
     to its class's type gives the result, which Core Lint checks as usual.

Not touched (their occurrences keep T, so whatever reaches them is exposed):
binders that are exported, have stable unfoldings or rules, or are mentioned
by those or by the module's rules ('pinned'); coercion variables; type and
data family applications; kinds.  Coercions get copies like types (Note
[Copies in coercions]).

Eligible types: algebraic data types with at least one constructor and some
field, not newtypes, classes, unboxed tuples or sums, family instances,
enumerations, or boxes of primitives (Int, Char, Double: one constructor,
all fields unlifted); every constructor vanilla (no existentials or equalities),
with no wrapper (so no strict or unpacked fields, for now); kinds closed.
-}

-- | The result of splitting
data DataSplitResult = DataSplitResult
  { dsr_binds   :: CoreProgram        -- ^ the new program
  , dsr_tycons  :: [TyCon]            -- ^ the new types
  , dsr_dump    :: SDoc               -- ^ for -ddump-webs-data
  , dsr_lint    :: DataLintResult     -- ^ Data Lint on the annotated program
  , dsr_changed :: Bool
  , dsr_useful  :: [Int]              -- ^ the classes whose split changed something
                                      --   (Note [Keeping only useful splits])
  , dsr_stages  :: [(String, ())] }   -- ^ for -dshow-passes: forcing each in turn
                                      --   times the steps of splitting

------------------------------------------------------------------
--      Eligibility
------------------------------------------------------------------

eligible :: TyCon -> Bool
eligible tc
  =  isAlgTyCon tc && isDataTyCon tc
  && not (isUnboxedTupleTyCon tc) && not (isUnboxedSumTyCon tc)
  && not (isClassTyCon tc) && not (isFamInstTyCon tc) && not (isTypeDataTyCon tc)
  && not (isEnumerationTyCon tc)
  && not prim_box
  && not (null dcs) && any (not . null . dataConOrigArgTys) dcs
  && all ok_dc dcs
  && all ok_binder (tyConBinders tc)
  where
    dcs = tyConDataCons tc
    ok_dc dc = isVanillaDataCon dc && null (dataConTheta dc)
               && isNothing (dataConWrapId_maybe dc)
    ok_binder b = not (isNamedTyConBinder b) && noFreeVarsOfType (tyVarKind (binderVar b))
    -- A box of primitives (Int, Char, Double, ...): a copy gains nothing
    -- (fields of this type are unboxed through the original anyway), and
    -- loses what GHC and the RTS do for the real one (e.g. the shared
    -- small-Int closures): nofib spectral/multiplier, which splits only
    -- Ints, ran 10% more instructions
    prim_box = case dcs of
      [dc] -> all (isUnliftedType . scaledThing) (dataConOrigArgTys dc)
      _    -> False

-- | A newtype whose representation mentions a type we copy
-- (Note [Splitting newtypes])
eligibleNewtype :: TyCon -> Bool
eligibleNewtype tc
  =  isNewTyCon tc && not (isClassTyCon tc) && not (isFamInstTyCon tc)
  && all ok_binder (tyConBinders tc)
  && any (\t -> t /= tc && (eligible t || (isNewTyCon t && not (isClassTyCon t))))
         (nonDetEltsUniqSet (tyConsOfType (snd (newTyConRhs tc))))
  where
    ok_binder b = not (isNamedTyConBinder b) && noFreeVarsOfType (tyVarKind (binderVar b))

-- | What annotation copies: data types and newtypes
copyable :: TyCon -> Bool
copyable tc = eligible tc || eligibleNewtype tc

{- Note [Copies keep strictness]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A constructor with strict fields of a type variable needs no wrapper (its
worker is strict: Note [Data-con worker strictness] in GHC.Core.DataCon), so
it is eligible -- Data.Complex's  !a :+ !a.  Every rebuild of a constructor
(a copy, a specialised or a flattened type) keeps each field's source bang,
implementation bang and strictness mark; flattened components take their
own constructor's.  (Building them lazy made the split Complex lazier than
Complex: case undefined :+ 1 of _ :+ _ -> "ok" no longer diverged, and nofib
imaginary/x2n1 stored thunks where it had stored values.)  A strict field
evaluates whatever it is given, so for unboxing any argument will do.
-}

{- Note [Keeping only useful splits]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A split that changes nothing -- no field unboxed, no constructor dropped --
buys nothing, and costs: GHC cannot share equal expressions at two
different copy types (nofib spectral/cichelli built [0 .. maxval] twice,
where it had shared it), specialisations made for the original type no
longer apply, and every split type has its own info tables.  On nofib,
splitting alone was +1.7% instructions on cichelli, +1.4% on event.

So with unboxing on, splitting runs twice.  The first pass finds the classes
whose split changed something; the second splits only those, and puts every
other class back on the original type (always well typed: a class is
closed, as for a class that builds nothing).  A newtype class is kept if one
of its children's classes is (its axiom names them), transitively: a child
may be a newtype class kept for its own children.  The two passes share
annotation, the pairs and the classes (splitDataTypes, applied to all but
the kept classes); only the classes' fates and what follows from them --
rewriting, specialising, flattening -- are computed twice.
-}

{- Note [Specialising for webs]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A split that specialisation (Note [Specialising split types] in
GHC.WebCore.DataSpec) gives a function field with a product argument or
result is useful too, though it unboxes nothing:

    data P a = P Int (a -> Int)      -- used only at P (Int, Int)

P's copy is P_s Int ((Int, Int) -> Int).  Its fields are hidden (Note
[Hidden fields] in GHC.WebCore.Sigs), and the field's web can now be raised;
on the original, the definition's field takes one polymorphic parameter
(Note [Signatures in the program] in GHC.WebCore.HiddenFields).  Data
splitting runs before the web pipeline, so it cannot tell whether raising
will fire; more product arguments or results of functions in the fields
than before specialisation is the cheap test (Int counts: a -> Int already
has one).
-}

{- Note [Splitting newtypes]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A local newtype N = MkN [Int] is a cast: its axiom N ~R# [Int] names the
list type itself, so if the axiom kept its type, every list that goes into
an N would meet the original [] and be exposed.  So newtypes are copied too.
A copy N_c gets fresh copies of the types its representation mentions (its
children; occurrences of N itself are N_c), and its own axiom N_c ~R# rep_c
(with those fresh copies).  An occurrence of N's axiom in a coercion becomes
the axiom of a fresh copy of N.

Two copies of N that are unified must have their representations unified
too: solving is a congruence closure.  When N_c1 and N_c2 are in one class,
their children are paired position by position; when a copy of N meets N
itself, its children meet their originals (they are exposed).  Repeat until
nothing changes.

A non-exposed class of copies of N becomes one new newtype, whose
representation maps the children to their classes' types, with its axiom.
Specialisation and flattening do not rebuild newtypes yet, so the data
types a split newtype's representation reaches are left out of them.
-}

------------------------------------------------------------------
--      Copies
------------------------------------------------------------------

-- | A copy of a newtype with the given representation (in terms of the
-- newtype's own type variables), and its axiom
mkNewtypeCopy :: UniqSupply -> (Unique -> OccName -> Name) -> OccName -> TyCon -> Type -> TyCon
mkNewtypeCopy us mk_name tc_occ tc rhs = tycon
  where
    (u_tc, u_ax, u_dc, u_wk) = case uniqsFromSupply us of
                                 (a : b : c : d : _) -> (a, b, c, d)
                                 _                   -> panic "mkNewtypeCopy"
    tvs     = tyConTyVars tc
    tc_name = mk_name u_tc tc_occ
    ax_name = mk_name u_ax (mkNewTyCoOcc tc_occ)
    odc     = case tyConDataCons tc of
                [dc'] -> dc'
                _     -> pprPanic "mkNewtypeCopy" (ppr tc)
    fixed   = case algTyConRhs tc of
                NewTyCon { nt_fixed_rep = fr } -> fr
                _                              -> True
    -- Eta-reduced as the original is (Note [Newtype eta] in GHC.Core.TyCon):
    -- an occurrence of the original's axiom has its number of arguments
    (etad_tvs0, _) = newTyConEtadRhs tc
    k         = length tvs - length etad_tvs0
    etad_tvs  = take (length tvs - k) tvs
    etad_rhs  = case splitAppTys rhs of
                  (h, args) -> mkAppTys h (take (length args - k) args)
    ax      = mkNewTypeCoAxiom ax_name tycon etad_tvs (take (length etad_tvs) (tyConRoles tc)) etad_rhs
    tycon   = mkAlgTyCon tc_name (tyConBinders tc) (tyConResKind tc) (tyConRoles tc)
                         Nothing [] new_rhs
                         (VanillaAlgTyCon (mkPrelTyConRepName tc_name)) False
    new_rhs = NewTyCon { data_con = dc, nt_rhs = rhs, nt_etad_rhs = (etad_tvs, etad_rhs)
                       , nt_co = ax, nt_fixed_rep = fixed }
    univs   = dataConUnivTyVars odc
    field   = substTy (zipTvSubst tvs (mkTyVarTys univs)) rhs
    mult    = case dataConOrigArgTys odc of
                (Scaled m _ : _) -> m
                []               -> ManyTy
    no_bang = HsSrcBang NoSourceText NoSrcUnpack NoSrcStrict
    dc_name = mk_name u_dc (getOccName odc)
    wk_name = mk_name u_wk (mkDataConWorkerOcc (getOccName odc))
    dc = mkDataCon dc_name False (mkPrelTyConRepName dc_name)
           [no_bang] [HsLazy] [NotMarkedStrict]
           [] univs [] emptyNameEnv (dataConUserTyVarBinders odc) [] []
           [Scaled mult field] (mkTyConApp tycon (mkTyVarTys univs))
           NoPromInfo tycon 1 [] (mkDataConWorkId wk_name dc) NoDataConRep

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
        univs   = dataConUnivTyVars dc
        -- The copy is as strict as the original (Note [Copies keep strictness])
        dc' = mkDataCon dc_name False (mkPrelTyConRepName dc_name)
                (dataConSrcBangs dc) (dataConImplBangs dc) (dataConRepStrictness dc)
                [] univs [] emptyNameEnv (dataConUserTyVarBinders dc) [] []
                arg_tys (mkTyConApp tycon (mkTyVarTys univs))
                NoPromInfo tycon tag [] (mkDataConWorkId wk_name dc') NoDataConRep

-- | A constructor of a type with a given original tag.  The constructor at
-- position tag-1 first: in originals and annotation copies it is the one,
-- and finding it walks only the list's spine.  A copy's constructors are
-- built lazily, and searching by tag would build every constructor before
-- the one wanted: quadratic in the constructors over a case's alternatives,
-- which ran GHC.Builtin.PrimOps (PrimOp: ~1500 constructors, info tables
-- matching all of them) out of memory when building GHC with webs.
conWithTag :: TyCon -> Int -> Maybe DataCon
conWithTag tc tag
  | (dc : _) <- drop (tag - 1) dcs, tag >= 1, dataConTag dc == tag = Just dc
  | otherwise = case [ dc | dc <- dcs, dataConTag dc == tag ] of
      (dc : _) -> Just dc
      []       -> Nothing
  where dcs = tyConDataCons tc

------------------------------------------------------------------
--      Traversal
------------------------------------------------------------------

-- | How to rewrite a program: types, binders, constructor occurrences, and
-- case alternatives (given the new case binder; Nothing drops it)
data Mapper m = Mapper
  { m_ty   :: Type -> m Type
  , m_bndr :: Id -> m Id
  , m_con  :: DataCon -> m Id
  , m_alt  :: Id -> DataCon -> m (Maybe DataCon)
  , m_co   :: Coercion -> m Coercion }

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
      Coercion co -> Coercion <$> m_co mp co
      -- A non-parametric function's type arguments keep their types
      -- (Note [Non-parametric functions])
      App {}
        | (Var v, args) <- collectArgs expr, nonParametric v
        -> mkApps (Var v) <$> mapM (\a -> case a of
                                      Type _ -> return a
                                      _      -> go env a) args
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
      Cast e co   -> Cast <$> go env e <*> m_co mp co
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

-- | Map the type constructors of the types inside a coercion, as 'mapTyCons'
-- (Note [Copies in coercions]).  Kinds and kind coercions are left alone,
-- as are coercion variables.
mapTyConsCo :: Monad m => (TyCon -> Bool) -> (TyCon -> m TyCon) -> Coercion -> m Coercion
mapTyConsCo want f = go
  where
    ty = mapTyCons want f
    go co = case co of
      Refl t               -> Refl <$> ty t
      GRefl r t mco        -> (\t' -> GRefl r t' mco) <$> ty t
      TyConAppCo r tc cos
        | isFamilyTyCon tc -> return co
        | want tc          -> TyConAppCo r <$> f tc <*> mapM go cos
        | otherwise        -> TyConAppCo r tc <$> mapM go cos
      AppCo c1 c2          -> AppCo <$> go c1 <*> go c2
      ForAllCo { fco_body = b } -> (\b' -> co { fco_body = b' }) <$> go b
      FunCo { fco_arg = a, fco_res = r }
                           -> (\a' r' -> co { fco_arg = a', fco_res = r' }) <$> go a <*> go r
      AxiomCo ax cos       -> AxiomCo <$> axiom ax <*> mapM go cos
      -- A UnivCo (unsafeCoerce) keeps its types: it asserts that its two
      -- sides have the same representation, and Lint does not relate them,
      -- so copies on its two sides could be split, and unboxed, apart.
      -- With the original types, what passes through it is exposed.
      UnivCo {}            -> return co
      SymCo c              -> SymCo <$> go c
      TransCo c1 c2        -> TransCo <$> go c1 <*> go c2
      SelCo cs c           -> SelCo cs <$> go c
      LRCo lr c            -> LRCo lr <$> go c
      InstCo c a           -> InstCo <$> go c <*> go a
      SubCo c              -> SubCo <$> go c
      _                    -> return co   -- CoVarCo, KindCo, HoleCo
    -- A newtype's axiom: the axiom of its copy (Note [Splitting newtypes] in
    -- GHC.WebCore.DataSplit)
    axiom rule@(UnbranchedAxiom ax)
      | let tc = coAxiomTyCon ax
      , isNewTyCon tc, want tc
      , Just ax0 <- newTyConCo_maybe tc, getUnique ax0 == getUnique ax
      = do { tc' <- f tc
           ; return (maybe rule UnbranchedAxiom (newTyConCo_maybe tc')) }
    axiom rule = return rule

{- Note [Copies in coercions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
As web inference does for arrows (FunCo's web), annotation puts copies into
the types inside coercions: Refl, GRefl, TyConAppCo, and the argument
coercions of an axiom (whose own types stay original, like an exposed
signature).  Not UnivCo (unsafeCoerce): it asserts that its two sides have
the same representation, but Lint does not relate them, so copies on its two
sides would be split and unboxed independently (test dsedge010 segfaulted).
It keeps the original types, exposing what passes through it.  Data Lint compares coercion kinds up to copies where
Core Lint compares them with ensureEqTys (casts, TransCo), so a value can
pass through a cast -- e.g. into a local newtype -- without exposing its
class.  Coercion variables keep their types (what flows through them is
exposed), and so do kinds.  The rewrite maps copies in coercions too.
-}

-- | Imported functions that are not parametric: unsafeCoerce relates the
-- representations of its type arguments (Note [Non-parametric functions])
nonParametric :: Id -> Bool
nonParametric v
  | Just AtomicModifyMutVar2Op <- isPrimOpId_maybe v
  = True
  | Just m <- nameModule_maybe (idName v)
  , moduleNameString (moduleName m) `elem` ["GHC.Internal.Unsafe.Coerce", "Unsafe.Coerce"]
  = True
  | otherwise
  = getOccString v `elem` ["unsafeCoerce#", "unsafeCoerce", "unsafeEqualityProof"]

{- Note [Non-parametric functions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Splitting relies on the parametricity of imported polymorphic functions: a
type variable in an imported signature exposes nothing, since the function
cannot look inside values of that type (id @[Int] xs leaves xs local).
unsafeCoerce @A @B is not parametric: it asserts that A and B have the same
representation.  Copies in its two type arguments would be split (and
unboxed) independently, and the program would read one layout as the other
(test dsedge010 segfaulted).  So the type arguments of the functions in
Unsafe.Coerce keep their original types: what passes through them meets the
original types and is exposed.  (A UnivCo keeps its types for the same
reason; Note [Copies in coercions].)

atomicModifyMutVar2# :: MutVar# s a -> (a -> c) -> State# s -> (# State# s, a, c #)
is not parametric in c either: the RTS takes the new contents out of f's
result with a selector thunk on its first field, so c must be a pair-like
constructor whose first field is the new value.  No case in the program
reads that field, so with c a split copy, dead-field elimination dropped it
(and useless elimination filled it with an absent error), and the IORef got
the second field instead (aeson's Data.Aeson.Internal.TH, whose letrecE
uses atomicModifyIORef: GHC segfaulted running deriveToJSON's splices;
test datasplit007).
-}

{- Note [Types used as kinds]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A type can be used as a kind: GHC.Generics' FixityI instantiates SingI's
kind variable in the Constructor instances' SingI axioms, at 'PrefixI
(Hackage pretty-show: N:SingI <FixityI>_N <'PrefixI>_N).  Copying it there
would leave the promoted constructor with the original's kind, and the axiom
application would no longer check (Data Lint: "Bad axiom application").
Such types are not copied anywhere: usedAsKinds collects the types in the
kinds of the program's type variables, and in the dependent (named)
arguments of type constructors in the program's types and coercion kinds:
SingI's kind argument FixityI above, a promoted constructor's kind argument
('[] @RuntimeRep).

Only those.  Excluding every type whose constructors are used promoted
somewhere would exclude lists and Bool, whose promoted constructors are in
most programs' types (the 'False of the Generics metadata, type-level lists),
and nothing would be split (datasplit001).  An earlier version excluded a
type that occurs in some type next to one of its own promoted constructors:
an unboxed tuple's hidden representation arguments count, so
(# State# RealWorld, [String] #), whose first representation is
TupleRep '[], excluded lists from every program with IO (nofib queens,
integer, cryptarithm2: datasplit009).
-}

-- | The types used at the kind level (Note [Types used as kinds])
-- (each with a type that shows it, for -ddump-webs-data)
usedAsKinds :: CoreProgram -> UniqFM TyCon (TyCon, String, Type)
usedAsKinds binds = kinded
  where
    kinded = listToUFM_C (\a _ -> a) (concatMap kindLevel (concatMap bindTypes binds))
    -- the kinds of type variables, and the dependent arguments of type
    -- constructors (a poly-kinded class's kind, a promoted constructor's)
    kindLevel (Left k)   = [ (tc, (tc, "in the kind", k)) | tc <- tyconsOf k ]
    kindLevel (Right ty) = [ (tc, (tc, "in a dependent argument of", ty))
                           | tc <- dependent ty ]
    dependent ty
      | Just ty' <- coreView ty = dependent ty'
    dependent ty = case ty of
      TyConApp tc args
        -> concat [ if isNamedTyConBinder b then tyconsOf a else dependent a
                  | (b, a) <- zip (tyConBinders tc) args ]
           ++ concatMap dependent (drop (length (tyConBinders tc)) args)
      FunTy { ft_arg = a, ft_res = r } -> dependent a ++ dependent r
      AppTy a b                        -> dependent a ++ dependent b
      ForAllTy b t                     -> tyconsOf (tyVarKind (binderVar b)) ++ dependent t
      CastTy t _                       -> dependent t
      _                                -> []
    tyconsOf t = nonDetEltsUniqSet (tyConsOfType t)
    bindTypes b = concat [ bndrTypes x ++ exprTypes e | (x, e) <- flattenBinds [b] ]
    bndrTypes x | isTyVar x = [Left (tyVarKind x)]
                | otherwise = [Right (varType x)]
    exprTypes e = case e of
      Type t        -> [Right t]
      Coercion co   -> coTypes co
      App f a       -> exprTypes f ++ exprTypes a
      Lam x b       -> bndrTypes x ++ exprTypes b
      Let b x       -> bindTypes b ++ exprTypes x
      Case s x t as -> exprTypes s ++ bndrTypes x ++ [Right t]
                       ++ concat [ concatMap bndrTypes bs ++ exprTypes r | Alt _ bs r <- as ]
      Cast x co     -> exprTypes x ++ coTypes co
      Tick _ x      -> exprTypes x
      _             -> []
    coTypes co = let Pair l r = coercionKind co in [Right l, Right r]

------------------------------------------------------------------
--      Annotation
------------------------------------------------------------------

data AnnState = AnnState
  { as_mod     :: Module
  , as_us      :: UniqSupply
  , as_copies  :: Copies
  , as_all     :: [TyCon]           -- ^ every copy
  , as_children :: UniqFM TyCon [TyCon]  -- ^ a newtype copy's children (Note [Splitting newtypes])
  , as_built   :: [(TyCon, Int)]    -- ^ copy, tag of a constructor built there
  , as_matched :: [(TyCon, Int)]    -- ^ copy, tag of a constructor matched there
  , as_kinded  :: TyCon -> Bool }   -- ^ used at the kind level: not copied
                                    --   (Note [Types used as kinds])

type AnnM = State AnnState

newCopy :: TyCon -> AnnM TyCon
newCopy tc
  | isNewTyCon tc = newNewtypeCopy tc
  | otherwise     = newDataCopy tc

-- | A copy of a newtype: fresh copies of the types in its representation,
-- then the copy itself (its own occurrences in the representation are it)
newNewtypeCopy :: TyCon -> AnnM TyCon
newNewtypeCopy tc = do
  { let (_, rhs) = newTyConRhs tc
  ; kinded <- gets as_kinded
  ; rhs0 <- mapTyCons (\t -> copyable t && not (kinded t) && t /= tc) newCopy rhs
  ; s <- get
  ; let (us1, us2) = splitUniqSupply (as_us s)
        selfTo c' = runIdentity . mapTyCons (== tc) (\_ -> return c')
        c = mkNewtypeCopy us1 (\u occ -> mkExternalName u (as_mod s) occ noSrcSpan) (getOccName tc)
                          tc (selfTo c rhs0)
        children = [ t | t <- tyConsInOrder rhs0, t `elemUFM` as_copies s ]
  ; put s { as_us = us2, as_copies = addToUFM (as_copies s) c tc, as_all = c : as_all s
          , as_children = addToUFM (as_children s) c children }
  ; return c }

-- | The type constructors of a type, left to right, with repetitions
tyConsInOrder :: Type -> [TyCon]
tyConsInOrder ty = case ty of
  TyConApp tc tys -> tc : concatMap tyConsInOrder tys
  FunTy { ft_arg = a, ft_res = r } -> tyConsInOrder a ++ tyConsInOrder r
  AppTy t1 t2  -> tyConsInOrder t1 ++ tyConsInOrder t2
  ForAllTy _ t -> tyConsInOrder t
  CastTy t _   -> tyConsInOrder t
  _            -> []

newDataCopy :: TyCon -> AnnM TyCon
newDataCopy tc = do
  { s <- get
  ; let (us1, us2) = splitUniqSupply (as_us s)
        c = mkCopy us1 (\u occ -> mkExternalName u (as_mod s) occ noSrcSpan) (getOccName tc)
                   (\dc _ -> getOccName dc) tc (tyConDataCons tc)
  ; put s { as_us = us2, as_copies = addToUFM (as_copies s) c tc, as_all = c : as_all s }
  ; return c }

annMapper :: VarSet -> (TyCon -> Bool) -> Mapper AnnM
annMapper pinned kinded = Mapper
  { m_ty   = ann_ty
  , m_bndr = \b -> if b `elemVarSet` pinned || isCoVar b then return (zap b)
                   else do { t <- ann_ty (idType b); return (zap (setIdType b t)) }
  , m_con  = \dc -> if eligible' (dataConTyCon dc)
                    then do { c <- newCopy (dataConTyCon dc)
                            ; modify (\s -> s { as_built = (c, dataConTag dc) : as_built s })
                            ; return (dataConWorkId (con c dc)) }
                    else return (dataConWorkId dc)
  , m_alt  = \b dc -> case splitTyConApp_maybe (idType b) of
      Just (c, _) | c /= dataConTyCon dc, eligible' (dataConTyCon dc)
        -> do { modify (\s -> s { as_matched = (c, dataConTag dc) : as_matched s })
              ; return (Just (con c dc)) }
      _ -> return (Just dc)
  , m_co   = mapTyConsCo copyable' newCopy }    -- Note [Copies in coercions]
  where
    -- Note [Types used as kinds]
    copyable' t = copyable t && not (kinded t)
    eligible' t = eligible t && not (kinded t)
    ann_ty = mapTyCons copyable' newCopy
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
    -- prepending (addToUFM_C's combining function gets the old value first):
    -- appending is quadratic in a type constructor's number of pairs
    adj = foldl' (\m (a, b) -> addToUFM_C prepend (addToUFM_C prepend m a [b]) b [a]) emptyUFM
                 (bagToList pairs)
    all_nodes = nodes ++ concat [ [a, b] | (a, b) <- bagToList pairs ]
    prepend old new = new ++ old
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

-- | Where the pairs of copies come from (Note [Inferring copy pairs] in
-- GHC.WebCore.DataInfer)
data PairSource
  = FromDataLint      -- ^ Data Lint type-checks the annotated program
  | FromInference     -- ^ unification, without type-checking
  | CheckInference    -- ^ both; the classes must be the same (panics if not)

-- | What a class of copies becomes: the original, or a new type with the
-- constructors the class builds (by original tag)
data Fate = Exposed | Bottom | Split TyCon [(Int, DataCon)]

splitDataTypes :: String          -- ^ The copies' suffix, before their class number
               -> PairSource
               -> Maybe UnboxOpts -> LintConfig -> Module -> UniqSupply -> [CoreRule]
               -> CoreProgram
               -> Maybe [Int]      -- ^ the classes to keep (Note [Keeping only useful splits])
               -> DataSplitResult
-- Annotation, the pairs and the classes do not depend on which classes are
-- kept: applied to all but the last argument, it computes them once for
-- both passes (Note [Keeping only useful splits])
splitDataTypes sfx source unbox cfg this_mod us rules binds = split_with
  where
    split_with keep = DataSplitResult
        { dsr_binds   = final_binds
        , dsr_tycons  = final_tcs
        , dsr_dump    = dump $$ flat_dump
        , dsr_lint    = lint_res
        , dsr_changed = changed
        , dsr_useful  = useful
        , dsr_stages  = stages }
      where
        split_binds = evalState (mapProgram rwMapper ann_binds) ()
        -- Unbox fields of the new types (Note [Flattening fields] in
        -- GHC.WebCore.DataFlatten)
        (final_binds, final_tcs, flat_dump, flat_rebuilt, flat_stages)
          | not changed = (binds, [], empty, [], [])
          | Just opts0 <- unbox
                        = let (fl_binds, fl_tcs, fl_dump, fl_rebuilt, fl_stages)
                                = flatten_rounds opts (uo_rounds opts0) us5 sp_tcs sp_binds
                              opts = opts0 { uo_orig_sizes = [ (occNameString (getOccName dc), dataConRepArity dc)
                                                             | tc <- sp_tcs, dc <- tyConDataCons tc ] }
                          in (fl_binds, fl_tcs ++ kept_tcs, sp_dump $$ fl_dump, fl_rebuilt, fl_stages)
          | otherwise   = (split_binds, new_tcs, empty, [], [])

        (sp_binds, sp_tcs, sp_dump) = specialiseSplit this_mod us4 data_tcs split_binds

        fates :: [([TyCon], TyCon, Fate, [Int], [Int])]    -- members, original, fate, built, matched
        fates = [ (ms, orig, fate, bs, mts)
                | (n, us_n, (orig, ms, bs, mts)) <- zip3 [1 :: Int ..] (drop 1 split_us) classes
                , let fate | any (not . is_copy) ms = Exposed
                           | not (kept n ms)        = Bottom   -- back to the original
                           | isNewTyCon orig        = mk_split_nt n us_n orig ms
                           | null bs                = Bottom
                           | otherwise              = mk_split n us_n orig bs ]

        -- Note [Keeping only useful splits]: in the second pass, a data class is
        -- split only if the first pass found its split useful; a newtype class
        -- only if one of its members' children's classes is kept (its axiom
        -- names them)
        kept n _ = case keep_set of
          Nothing -> True
          Just ks -> n `IntSet.member` ks
        -- The useful classes, and every newtype class with a kept child's
        -- class, transitively: a newtype class that goes back to the
        -- original takes the original axiom, whose representation names the
        -- original types, so none of its children may stay split -- and a
        -- child is often a newtype too (ExceptT inside a local UnifyM, kept
        -- for the Either inside it: futhark's Language.Futhark.TypeChecker.
        -- Unify was left ill-typed, testsuite datasplit011)
        keep_set = close . IntSet.fromList <$> keep
        close ks | IntSet.size ks' == IntSet.size ks = ks
                 | otherwise                         = close ks'
          where ks' = IntSet.union ks (IntSet.fromList
                        [ n | (n, chs) <- nt_children, any (`IntSet.member` ks) chs ])
        nt_children = [ (n, [ class_number ch | m <- ms, Just chs <- [children m], ch <- chs ])
                      | (n, (orig, ms, _, _)) <- zip [1 :: Int ..] classes, isNewTyCon orig ]
        -- The classes whose split changed something (first pass): a field
        -- unboxed in some round, or a constructor dropped.  The new types are
        -- named Orig_s<n> after their class, through every rebuild.
        useful = nub ([ n | tc <- flat_rebuilt, Just n <- [split_number tc] ] ++
                      -- Note [Specialising for webs]
                      [ n | (orig, sp) <- zip data_tcs sp_tcs
                          , getUnique orig /= getUnique sp
                          , product_funs sp > product_funs orig
                          , Just n <- [split_number sp] ] ++
                      [ n | (n, (_, orig, Split _ cons, _, _)) <- zip [1 :: Int ..] fates
                          , not (isNewTyCon orig)
                          , length cons < length (tyConDataCons orig) ])
        -- A newtype class: its representation, from one member, with the
        -- children mapped to their classes' types (lazily)
        mk_split_nt n us_n orig ms = Split tc []
          where
            member = head [ m | m <- ms, is_copy m ]
            tc = mkNewtypeCopy us_n (\u occ -> mkExternalName u this_mod occ noSrcSpan)
                               (mkTcOcc (occNameString (getOccName orig) ++ sfx ++ show n))
                               orig (evalState (rw_ty (snd (newTyConRhs member))) ())
        fate_of :: UniqFM TyCon Fate      -- every member of a class
        fate_of = listToUFM [ (m, f) | (ms, _, f, _, _) <- fates, m <- ms ]

        new_tcs = [ tc | (_, _, Split tc _, _, _) <- fates ]

        -- Specialisation and flattening rebuild data types, not newtypes: they
        -- leave out the split newtypes and every split type their
        -- representations reach (Note [Splitting newtypes])
        nt_reach = go_reach emptyUniqSet [ t | nt <- new_tcs, isNewTyCon nt
                                   , t <- nonDetEltsUniqSet (tyConsOfType (snd (newTyConRhs nt))) ]
        go_reach seen [] = seen
        go_reach seen (t : ts)
          | t `elementOfUniqSet` seen || not (t `elementOfUniqSet` new_set) = go_reach seen ts
          | otherwise = go_reach (addOneToUniqSet seen t) (field_tcs t ++ ts)
        new_set = mkUniqSet new_tcs
        field_tcs t
          | isNewTyCon t = nonDetEltsUniqSet (tyConsOfType (snd (newTyConRhs t)))
          | otherwise    = [ t' | dc <- tyConDataCons t, Scaled _ ft <- dataConOrigArgTys dc
                                , t' <- nonDetEltsUniqSet (tyConsOfType ft) ]
        data_tcs = [ tc | tc <- new_tcs, not (isNewTyCon tc), not (tc `elementOfUniqSet` nt_reach) ]
        kept_tcs = [ tc | tc <- new_tcs, isNewTyCon tc || tc `elementOfUniqSet` nt_reach ]
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
                              else return (Just dc)
          , m_co   = mapTyConsCo is_copy (return . final) }
        rw_ty = mapTyCons is_copy (return . final)

        -- Each stage forces what the next one needs, and no more (forcing an
        -- annotated program does not build its copies' constructors: Data Lint
        -- does).  Specialising and flattening are what is left.
        stages = [ ("annotation", seqBinds ann_binds `seq` sizeUFM copies `seq` ())
                 , ("Data Lint", ok `seq` length pairs `seq` ())
                 , ("solving", sizeUFM rep_of `seq` length all_nodes `seq` ())
                 , ("classes", foldr (\(ms, _, f, _, _) acc -> length ms `seq` f `seq` acc) () fates)
                 , ("rewriting", if changed then seqBinds split_binds else ())
                 , ("specialising", if changed && isJust unbox
                                    then seqBinds sp_binds `seq` length sp_tcs `seq` () else ()) ]
                 ++ flat_stages
                 ++ [ ("usefulness", changed `seq` length useful `seq` ()) ]

        dump = vcat
          [ text "Data Lint:" <+> (if ok then text "ok" else text "errors (not split)")
          , whenPprDebug $ text "pairs:" <+> int (length pairs)
          , text "copies:" <+> int (sizeUFM copies)
            <+> parens (int (nonDetFoldUFM (\o n -> n + length (tyConDataCons o)) 0 copies)
                        <+> text "constructors behind them") <> comma
            <+> text "classes:" <+> int (length fates) <> comma
            <+> text "exposed:" <+> int (length [ () | (_, _, Exposed, _, _) <- fates ]) <> comma
            <+> text "split:" <+> int (length new_tcs) <> comma
            <+> text "exposed only by casts:"
            <+> int (length [ () | (ms, _, Exposed, _, _) <- fates, exposed_by_cast ms ]) <> comma
            <+> text "pinned binders:" <+> int (sizeVarSet pinned)
          , whenPprDebug $ text "copies per type:" <+> pprWithCommas (\(n, t) -> ppr t <> colon <> int n)
              (take 25 (sortOn (negate . fst)
                 [ (n, t) | (t, n) <- nonDetEltsUFM (foldl' (\m o -> addToUFM_C (\(t, a) (_, b) -> (t, a + b)) m o (o, 1 :: Int))
                                                           emptyUFM (nonDetEltsUFM copies)) ]))
          , ppUnless (null kinded_list) $
            text "not copied (used as kinds):" <+> pprWithCommas ppr (map fst3 kinded_list)
          , whenPprDebug $ nest 2 $ vcat [ ppr tc <+> text why <+> ppr t | (tc, why, t) <- kinded_list ]
          , vcat [ ppr tc <+> text "=" <+> ppr orig
                   <+> text "with" <+> hsep (punctuate comma (map ppr (tyConDataCons tc)))
                   <+> parens (text "built" <+> ppr bs <> comma <+> text "matched" <+> ppr ms
                               <> (if length bs < length (tyConDataCons orig)
                                   then comma <+> text "dropped" <+> ppr [ dataConTag dc | dc <- tyConDataCons orig
                                                                        , dataConTag dc `notElem` bs ]
                                   else empty))
                 | (_, orig, Split tc _, bs, ms) <- fates, not (isNewTyCon orig) ]
          , whenPprDebug $ vcat
              [ ppr orig <> colon <+> pp_fate_short f <+> int (length ms) <+> text "members;"
                <+> text "children:" <+> ppr [ (m, ch) | m <- ms, Just ch <- [children m] ]
              | (ms, orig, f, _, _) <- fates, isNewTyCon orig ]
          , vcat [ ppr tc <+> text "= newtype" <+> ppr orig <+> text "~R#"
                   <+> ppr (snd (newTyConRhs tc))
                 | (_, orig, Split tc _, _, _) <- fates, isNewTyCon orig ] ]

    (us1, us23) = splitUniqSupply us
    (us2, us3)  = splitUniqSupply us23
    (us4, us5) = splitUniqSupply us3
    -- Each round unpacks one more level (Note [Flattening fields])
    -- (the last component: each round's two steps, for -dshow-passes)
    flatten_rounds _ 0 _ tcs bs = (bs, tcs, empty, [], [])
    -- Between rounds, the simple optimiser inlines the aliases a round leaves
    -- (let x = y) and takes apart the cases on constructors it builds, so
    -- that the next round sees the fields' real uses
    flatten_rounds opts n u tcs bs
      = let (u1, u2) = splitUniqSupply u
            (bs', tcs', d, steps) = flattenFields opts this_mod u1 tcs bs
            changed_round = map getUnique tcs' /= map getUnique tcs
            bs_opt | changed_round = map simple_bind bs'
                   | otherwise     = bs'
            old = mkUniqSet tcs
            rebuilt = [ tc | tc <- tcs', not (tc `elementOfUniqSet` old) ]
            (bs'', tcs'', d', r', st')
              | changed_round, n == 1
              = (bs_opt, tcs', text "round limit reached: the last round still unboxed", [], [])
              | changed_round = flatten_rounds opts (n - 1) u2 tcs' bs_opt
              | otherwise     = (bs', tcs', empty, [], [])
            round_stages = [ ("flattening (" ++ show n ++ " rounds left), " ++ w, v) | (w, v) <- steps ] ++
                           [ ("flattening (" ++ show n ++ " rounds left), rewrite", seqBinds bs' `seq` length tcs' `seq` ())
                           , ("flattening (" ++ show n ++ " rounds left), simple optimiser"
                             , if changed_round then seqBinds bs_opt else ()) ]
        in (bs'', tcs'', d $$ d', rebuilt ++ r', round_stages ++ st')
    simple_bind (NonRec b e) = NonRec b (simpleOptExpr defaultSimpleOpts e)
    simple_bind (Rec prs)    = Rec [ (b, simpleOptExpr defaultSimpleOpts e) | (b, e) <- prs ]
    pinned = pinnedIds rules binds
    (ann_binds, st) = runState (mapProgram (annMapper pinned kinded) binds)
                               (AnnState this_mod us1 emptyUFM [] emptyUFM [] [] kinded)
    kinded_set = usedAsKinds binds
    kinded tc = tc `elemUFM` kinded_set
    -- (for the dump: those that would otherwise be copied)
    kinded_list = sortOn (\(tc, _, _) -> getOccString tc)
                         [ k | k@(tc, _, _) <- nonDetEltsUFM kinded_set, copyable tc ]
    fst3 (a, _, _) = a
    copies   = as_copies st
    lint_res = case source of
      FromInference -> DataLintResult { dlr_warns = emptyBag, dlr_errs = emptyBag
                                      , dlr_pairs = inferred }
      _             -> lintDataProgram cfg copies ann_binds
    inferred = inferCopyPairs copies ann_binds
    ok       = isEmptyBag (dlr_errs lint_res) && checked && solve_checked
    pairs    = bagToList (dlr_pairs lint_res)
    -- -fcore-webs-data-infer-check: the same classes from both
    checked = case source of
      CheckInference
        | not (null mismatches)
        -> pprPanic "DataSplit: inferred classes differ from Data Lint's"
             (vcat [ ppr a <+> text "~" <+> ppr b <+> parens (text why) | (a, b, why) <- take 20 mismatches ])
      _ -> True
    mismatches
      = [ (a, b, "only inferred")  | (a, b) <- bagToList inferred
                                   , repOf lint_comps a /= repOf lint_comps b ] ++
        [ (a, b, "only Data Lint") | (a, b) <- bagToList (dlr_pairs lint_res)
                                   , repOf infer_comps a /= repOf infer_comps b ]
    lint_comps  = components (as_all st) (dlr_pairs lint_res)
    infer_comps = components (as_all st) inferred
    repOf m c = lookupWithDefaultUFM m c c
    is_copy c = c `elemUFM` copies

    -- How much casts cost: classes exposed only through a cast (pairs from
    -- casts removed, the class would not meet the original).  Approximate:
    -- a pair that also comes from elsewhere is removed too.
    cast_pairs = Set.fromList [ key_pair a b | (a, b) <- bagToList (castCopyPairs copies ann_binds) ]
    key_pair a b = (getKey (getUnique a), getKey (getUnique b))
    pairs_nc = listToBag [ p | p@(a, b) <- pairs, not (key_pair a b `Set.member` cast_pairs) ]
    rep_nc_of = components (as_all st) pairs_nc
    rep_nc c = lookupWithDefaultUFM rep_nc_of c c
    nc_exposed = mkUniqSet [ rep_nc o | (a, b) <- pairs, o <- [a, b], not (is_copy o) ]
    exposed_by_cast ms = not (any (\m -> rep_nc m `elementOfUniqSet` nc_exposed) ms)

    -- Classes: representative -> members, with congruence for newtype
    -- copies' children (Note [Splitting newtypes]), by an online union-find
    -- (Note [Solving copy classes online] in GHC.WebCore.DataInfer); the
    -- members include the originals that only congruence brings in
    (rep_of, all_nodes) = solveCopies copies children (as_all st) pairs
    children c = lookupUFM (as_children st) c
    -- -fcore-webs-data-infer-check: the old solver (components, then
    -- congruence in rounds) gives the same classes
    solve_checked = case source of
      CheckInference
        | let (old_rep, old_pairs) = congruence (as_all st) (dlr_pairs lint_res)
              old_nodes = nubTc (as_all st ++ concat [ [a, b] | (a, b) <- old_pairs ])
              -- the same nodes, and old and new representatives in a bijection
              r m n = lookupWithDefaultUFM m n n
              fwd = foldl' (\m n -> addToUFM_C (++) m (r old_rep n) [r rep_of n]) emptyUFM old_nodes
              bwd = foldl' (\m n -> addToUFM_C (++) m (r rep_of n) [r old_rep n]) emptyUFM all_nodes
              many xs = length (nubTc xs) > 1
              old_set = mkUniqSet old_nodes
              new_set = mkUniqSet all_nodes
              bad = [ (n, n) | n <- old_nodes, not (n `elementOfUniqSet` new_set) ]
                    ++ [ (n, n) | n <- all_nodes, not (n `elementOfUniqSet` old_set) ]
                    ++ [ (a, b) | xs@(a : b : _) <- nonDetEltsUFM fwd ++ nonDetEltsUFM bwd, many xs ]
        , not (null bad)
        -> pprPanic "DataSplit: online classes differ from the rounds'" (ppr (take 20 bad))
      _ -> True
    congruence nodes prs = go_cong (0 :: Int) prs
      where
        go_cong n ps
          | null new || n > 20 = (r, bagToList ps)
          | otherwise          = go_cong (n + 1) (ps `unionBags` listToBag new)
          where
            r = components nodes ps
            repr c = lookupWithDefaultUFM r c c
            cls = foldl' (\m c -> addToUFM_C (\old new -> new ++ old) m (repr c) [c]) emptyUFM
                        (nubTc (nodes ++ concat [ [a, b] | (a, b) <- bagToList ps ]))
            -- a pair already in the same class adds nothing
            new = [ p | p@(a, b) <- concatMap child_pairs (nonDetEltsUFM cls)
                      , repr a /= repr b ]
        child_pairs ms = case [ ch | m <- ms, Just ch <- [children m] ] of
          (ch0 : rest) -> concat [ zip ch0 ch | ch <- rest ]
                          ++ (if any (not . is_copy) ms
                              then [ (c, copyOriginal copies c) | c <- ch0 ] else [])
          []           -> []
    rep c  = lookupWithDefaultUFM rep_of c c
    members :: UniqFM TyCon [TyCon]
    -- (built in reverse, by prepending: appending is quadratic in a class's size)
    members = mapUFM reverse $
              foldl' (\m c -> addToUFM_C (\old new -> new ++ old) m (rep c) [c]) emptyUFM
                     all_nodes
    nubTc = nonDetEltsUniqSet . mkUniqSet

    -- (in any order: sorted below)
    built   = foldl' (\m (c, t) -> addToUFM_C (\old new -> new ++ old) m (rep c) [t]) emptyUFM (as_built st)
    matched = foldl' (\m (c, t) -> addToUFM_C (\old new -> new ++ old) m (rep c) [t]) emptyUFM (as_matched st)

    -- The classes, in a deterministic order (by their first copy)
    classes = map snd $ sortOn fst
                [ (foldl' min (getKey (getUnique m0)) (map (getKey . getUnique) ms)
                  , ( copyOriginal copies r, ms
                    , sortOn id (nub (lookupWithDefaultUFM built [] r))
                    , sortOn id (nub (lookupWithDefaultUFM matched [] r)) ))
                | ms@(m0 : _) <- nonDetEltsUFM members, let r = rep m0 ]
    -- class n's supply is element n (zipped, not indexed: (!!) is linear)
    split_us = listSplitUniqSupply us2

    class_number c = lookupWithDefaultUFM class_numbers 0 (rep c)
    class_numbers :: UniqFM TyCon Int
    class_numbers = listToUFM [ (rep m0, n) | (n, (_, m0 : _, _, _)) <- zip [1 :: Int ..] classes ]

    -- How many arguments and results of functions in the fields are products?
    -- (Specialisation adds some where a type variable was.)
    product_funs tc = sum [ go (scaledThing f) | dc <- tyConDataCons tc, f <- dataConRepArgTys dc ]
      where go :: Type -> Int
            go t = case splitFunTy_maybe t of
              Just (_, _, a, r) -> prod a + prod r + go a + go r
              Nothing -> case coreFullView t of
                TyConApp _ ts -> sum (map go ts)
                AppTy a b     -> go a + go b
                ForAllTy _ b  -> go b
                _             -> 0
            prod t | isJust (productCon (coreFullView t)) = 1
                   | otherwise                            = 0
    split_number tc = case reverse (occNameString (getOccName tc)) of
      str | (ds@(_ : _), rest) <- span isDigit str
          , reverse sfx `isPrefixOf` rest -> Just (read (reverse ds))
      _ -> Nothing
    mk_split n us_n orig tags = Split tc (zip tags (tyConDataCons tc))
      where
        tc = mkCopy us_n
                    (\u occ -> mkExternalName u this_mod occ noSrcSpan)
                    (mkTcOcc (occNameString (getOccName orig) ++ sfx ++ show n))
                    (\dc _ -> mkDataOcc (con_base dc ++ sfx ++ show n))
                    orig [ dc | dc <- tyConDataCons orig, dataConTag dc `elem` tags ]
    -- Constructors with alphanumeric names keep them; [], (:) and tuples
    -- become Con<tag>
    con_base dc = case occNameString (getOccName dc) of
      str@(c : _) | isUpper c -> str
      _                       -> "Con" ++ show (dataConTag dc)

    pp_fate_short Exposed     = text "exposed"
    pp_fate_short Bottom      = text "bottom"
    pp_fate_short (Split t _) = text "split as" <+> ppr t
-- | The pairs of copies that casts force together: a cast's coercion has the
-- original types, so its kind against the expression's type
castCopyPairs :: Copies -> CoreProgram -> Bag (TyCon, TyCon)
castCopyPairs copies binds = unionManyBags (map bind binds)
  where
    bind b = unionManyBags [ expr e | (_, e) <- flattenBinds [b] ]
    expr e = case e of
      Cast x co   -> copyPairs copies (coercionLKind co) (exprType x) `unionBags` expr x
      App f a     -> expr f `unionBags` expr a
      Lam _ b     -> expr b
      Let b x     -> bind b `unionBags` expr x
      Case s _ _ as -> unionManyBags (expr s : [ expr r | Alt _ _ r <- as ])
      Tick _ x    -> expr x
      _           -> emptyBag
