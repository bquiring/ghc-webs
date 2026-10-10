-- | Splitting data types by data flow: each class of occurrences of a data
-- type that never meets the outside world gets its own copy of the type.
--
-- See Note [Splitting data types].
module GHC.WebCore.DataSplit
  ( DataSplitResult(..)
  , splitDataTypes
  , mapTyCons
  , mapTyConsCo
  , nonParametric
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.DataCon
import GHC.Core.FVs ( rulesFreeVars, idRuleVars, idUnfoldingVars )
import GHC.Core.SimpleOpt ( simpleOptExpr, defaultSimpleOpts )
import GHC.Core.Multiplicity ( Scaled(..), scaledThing )
import GHC.Core.TyCo.Rep
import GHC.Core.TyCon
import GHC.Core.Type
import GHC.Core.Coercion ( coercionLKind, isCoVar )
import GHC.Core.Coercion.Axiom ( CoAxiomRule(..), coAxiomTyCon )
import GHC.Core.FamInstEnv ( mkNewTypeCoAxiom )
import Data.Functor.Identity ( runIdentity )
import GHC.Core.Utils ( exprType )

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

import GHC.Unit.Module ( Module, moduleName, moduleNameString )

import GHC.Utils.Outputable
import GHC.Utils.Panic ( panic, pprPanic )

import GHC.WebCore.DataCopy
import GHC.WebCore.DataLint ( LintConfig, DataLintResult(..), lintDataProgram )
import {-# SOURCE #-} GHC.WebCore.DataFlatten ( flattenFields )
import GHC.WebCore.DataSpec ( specialiseSplit )

import Control.Monad ( forM )
import Control.Monad.Trans.State.Strict
import Data.Char ( isUpper, isDigit )
import Data.List ( sortOn, nub )
import qualified Data.Map as Map
import Data.Maybe ( isNothing, isJust, catMaybes, fromMaybe )
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
  , dsr_exposure :: SDoc }            -- ^ why classes are exposed (-ddump-webs-stats)

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
of its children's classes is (its axiom names them).  Both passes use the
same unique supply, so the classes, and their numbers, are the same.
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
-}

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
  , as_matched :: [(TyCon, Int)] }  -- ^ copy, tag of a constructor matched there

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
  ; rhs0 <- mapTyCons (\t -> copyable t && t /= tc) newCopy rhs
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

annMapper :: VarSet -> Mapper AnnM
annMapper pinned = Mapper
  { m_ty   = ann_ty
  , m_bndr = \b -> if b `elemVarSet` pinned || isCoVar b then return (zap b)
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
      _ -> return (Just dc)
  , m_co   = mapTyConsCo copyable newCopy }    -- Note [Copies in coercions]
  where
    ann_ty = mapTyCons copyable newCopy
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

splitDataTypes :: Maybe UnboxOpts -> Maybe [Int] -> LintConfig -> Module -> UniqSupply -> [CoreRule]
               -> CoreProgram -> DataSplitResult
splitDataTypes unbox keep cfg this_mod us rules binds
  = DataSplitResult
      { dsr_binds   = final_binds
      , dsr_tycons  = final_tcs
      , dsr_dump    = dump $$ flat_dump
      , dsr_lint    = lint_res
      , dsr_changed = changed
      , dsr_useful  = useful
      , dsr_exposure = exposure }
  where
    (us1, us23) = splitUniqSupply us
    (us2, us3)  = splitUniqSupply us23
    split_binds = evalState (mapProgram rwMapper ann_binds) ()
    -- Unbox fields of the new types (Note [Flattening fields] in
    -- GHC.WebCore.DataFlatten)
    (final_binds, final_tcs, flat_dump, flat_rebuilt)
      | not changed = (binds, [], empty, [])
      | Just opts0 <- unbox
                    = let (fl_binds, fl_tcs, fl_dump, fl_rebuilt) = flatten_rounds opts (uo_rounds opts0) us5 sp_tcs sp_binds
                          opts = opts0 { uo_orig_sizes = [ (occNameString (getOccName dc), dataConRepArity dc)
                                                         | tc <- sp_tcs, dc <- tyConDataCons tc ] }
                      in (fl_binds, fl_tcs ++ kept_tcs, sp_dump $$ fl_dump, fl_rebuilt)
      | otherwise   = (split_binds, new_tcs, empty, [])

    (us4, us5) = splitUniqSupply us3
    (sp_binds, sp_tcs, sp_dump) = specialiseSplit this_mod us4 data_tcs split_binds

    -- Each round unpacks one more level (Note [Flattening fields])
    flatten_rounds _ 0 _ tcs bs = (bs, tcs, empty, [])
    -- Between rounds, the simple optimiser inlines the aliases a round leaves
    -- (let x = y) and takes apart the cases on constructors it builds, so
    -- that the next round sees the fields' real uses
    flatten_rounds opts n u tcs bs
      = let (u1, u2) = splitUniqSupply u
            (bs', tcs', d) = flattenFields opts this_mod u1 tcs bs
            changed_round = map getUnique tcs' /= map getUnique tcs
            bs_opt | changed_round = map simple_bind bs'
                   | otherwise     = bs'
            rebuilt = [ tc | tc <- tcs', getUnique tc `notElem` map getUnique tcs ]
            (bs'', tcs'', d', r')
              | changed_round, n == 1
              = (bs_opt, tcs', text "round limit reached: the last round still unboxed", [])
              | changed_round = flatten_rounds opts (n - 1) u2 tcs' bs_opt
              | otherwise     = (bs', tcs', empty, [])
        in (bs'', tcs'', d $$ d', rebuilt ++ r')
    simple_bind (NonRec b e) = NonRec b (simpleOptExpr defaultSimpleOpts e)
    simple_bind (Rec prs)    = Rec [ (b, simpleOptExpr defaultSimpleOpts e) | (b, e) <- prs ]
    pinned = pinnedIds rules binds
    (ann_binds, st) = runState (mapProgram (annMapper pinned) binds)
                               (AnnState this_mod us1 emptyUFM [] emptyUFM [] [])
    copies   = as_copies st
    lint_res = lintDataProgram cfg copies ann_binds
    ok       = isEmptyBag (dlr_errs lint_res)
    pairs    = bagToList (dlr_pairs lint_res)
    is_copy c = c `elemUFM` copies

    -- How much casts cost: classes exposed only through a cast (pairs from
    -- casts removed, the class would not meet the original).  Approximate:
    -- a pair that also comes from elsewhere is removed too.
    cast_pairs = [ (getUnique a, getUnique b) | (a, b) <- bagToList (castCopyPairs copies ann_binds) ]
    pairs_nc = listToBag [ p | p@(a, b) <- pairs, (getUnique a, getUnique b) `notElem` cast_pairs ]
    rep_nc_of = components (as_all st) pairs_nc
    rep_nc c = lookupWithDefaultUFM rep_nc_of c c
    nc_exposed = mkUniqSet [ rep_nc o | (a, b) <- pairs, o <- [a, b], not (is_copy o) ]
    exposed_by_cast ms = not (any (\m -> rep_nc m `elementOfUniqSet` nc_exposed) ms)

    -- Classes: representative -> members
    -- with congruence for newtype copies' children (Note [Splitting newtypes])
    -- (all_pairs: Data Lint's and congruence's; the members of a class come
    -- from them, so that an original only congruence brings in counts)
    (rep_of, all_pairs) = congruence (as_all st) (dlr_pairs lint_res)
    children c = lookupUFM (as_children st) c
    congruence nodes prs = go_cong (0 :: Int) prs
      where
        go_cong n ps
          | null new || n > 20 = (r, bagToList ps)
          | otherwise          = go_cong (n + 1) (ps `unionBags` listToBag new)
          where
            r = components nodes ps
            repr c = lookupWithDefaultUFM r c c
            cls = foldl (\m c -> addToUFM_C (++) m (repr c) [c]) emptyUFM
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
    members = foldl (\m c -> addToUFM_C (++) m (rep c) [c]) emptyUFM
                    (nubTc (as_all st ++ concat [ [a, b] | (a, b) <- all_pairs ]))
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
                       | not (kept n ms)        = Bottom   -- back to the original
                       | isNewTyCon orig        = mk_split_nt n orig ms
                       | null bs                = Bottom
                       | otherwise              = mk_split n orig bs ]

    split_us = listSplitUniqSupply us2

    -- Note [Keeping only useful splits]: in the second pass, a data class is
    -- split only if the first pass found its split useful; a newtype class
    -- only if one of its members' children's classes is kept (its axiom
    -- names them)
    kept n ms = case keep of
      Nothing -> True
      Just ks
        | any (isNewTyCon . copyOriginal copies) (take 1 ms)
        -> any (\c -> class_number c `elem` ks)
               [ ch | m <- ms, Just chs <- [children m], ch <- chs ]
        | otherwise -> n `elem` ks
    class_number c = fromMaybe 0 (lookup (getUnique (rep c)) class_numbers)
    class_numbers = [ (getUnique (rep m0), n) | (n, (_, m0 : _, _, _)) <- zip [1 :: Int ..] classes ]

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
      str | (ds@(_ : _), 's' : '_' : _) <- span isDigit str -> Just (read (reverse ds))
      _ -> Nothing
    mk_split n orig tags = Split tc (zip tags (tyConDataCons tc))
      where
        tc = mkCopy (split_us !! n)
                    (\u occ -> mkExternalName u this_mod occ noSrcSpan)
                    (mkTcOcc (occNameString (getOccName orig) ++ "_s" ++ show n))
                    (\dc _ -> mkDataOcc (con_base dc ++ "_s" ++ show n))
                    orig [ dc | dc <- tyConDataCons orig, dataConTag dc `elem` tags ]
    -- A newtype class: its representation, from one member, with the
    -- children mapped to their classes' types (lazily)
    mk_split_nt n orig ms = Split tc []
      where
        member = head [ m | m <- ms, is_copy m ]
        tc = mkNewtypeCopy (split_us !! n) (\u occ -> mkExternalName u this_mod occ noSrcSpan)
                           (mkTcOcc (occNameString (getOccName orig) ++ "_s" ++ show n))
                           orig (evalState (rw_ty (snd (newTyConRhs member))) ())
    -- Constructors with alphanumeric names keep them; [], (:) and tuples
    -- become Con<tag>
    con_base dc = case occNameString (getOccName dc) of
      str@(c : _) | isUpper c -> str
      _                       -> "Con" ++ show (dataConTag dc)

    fate_of :: UniqFM TyCon Fate      -- every member of a class
    fate_of = listToUFM [ (m, f) | (ms, _, f, _, _) <- fates, m <- ms ]

    new_tcs = [ tc | (_, _, Split tc _, _, _) <- fates ]

    -- Specialisation and flattening rebuild data types, not newtypes: they
    -- leave out the split newtypes and every split type their
    -- representations reach (Note [Splitting newtypes])
    nt_reach = go_reach [] [ t | nt <- new_tcs, isNewTyCon nt
                               , t <- nonDetEltsUniqSet (tyConsOfType (snd (newTyConRhs nt))) ]
    go_reach seen [] = seen
    go_reach seen (t : ts)
      | t `elem` seen || t `notElem` new_tcs = go_reach seen ts
      | otherwise = go_reach (t : seen) (field_tcs t ++ ts)
    field_tcs t
      | isNewTyCon t = nonDetEltsUniqSet (tyConsOfType (snd (newTyConRhs t)))
      | otherwise    = [ t' | dc <- tyConDataCons t, Scaled _ ft <- dataConOrigArgTys dc
                            , t' <- nonDetEltsUniqSet (tyConsOfType ft) ]
    data_tcs = [ tc | tc <- new_tcs, not (isNewTyCon tc), tc `notElem` nt_reach ]
    kept_tcs = [ tc | tc <- new_tcs, isNewTyCon tc || tc `elem` nt_reach ]
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

    -- Why each exposed class is exposed (WEBS-BACKLOG.md, "What exposes data
    -- types?"): the global functions whose applications tied a copy in it to
    -- the original type (dlr_origins); "other" for any other place
    exposure = vcat ([ text "Exposed data classes by:" <+> text why <> colon <+> int n
                     | (why, n) <- count (concatMap whys exposed_reps) ] ++
                     [ text "Exposed data classes only by:" <+> text why <> colon <+> int n
                     | (why, n) <- count [ y | r <- exposed_reps, [y] <- [whys r] ] ])
    exposed_reps = [ rep m | (m : _, _, Exposed, _, _) <- fates ]
    origin_map = foldl (\m (c, why) -> addToUFM_C (++) m (rep c) [why]) emptyUFM
                   [ (if is_copy a then a else b, maybe "other" origin_name h)
                   | ((a, b), h) <- bagToList (dlr_origins lint_res)
                   , not (is_copy a && is_copy b) ]
    whys r = nub (lookupWithDefaultUFM origin_map ["(no pair recorded)"] r)
    count xs = Map.toList (Map.fromListWith (+) [ (x, 1 :: Int) | x <- xs ])
    origin_name n = (if isDataOcc (nameOccName n) then "constructor " else "")
                    ++ maybe "" (\m -> moduleNameString (moduleName m) ++ ".") (nameModule_maybe n)
                    ++ occNameString (nameOccName n)

    pp_fate_short Exposed     = text "exposed"
    pp_fate_short Bottom      = text "bottom"
    pp_fate_short (Split t _) = text "split as" <+> ppr t
    dump = vcat
      [ text "Data Lint:" <+> (if ok then text "ok" else text "errors (not split)")
      , text "copies:" <+> int (sizeUFM copies) <> comma
        <+> text "classes:" <+> int (length fates) <> comma
        <+> text "exposed:" <+> int (length [ () | (_, _, Exposed, _, _) <- fates ]) <> comma
        <+> text "split:" <+> int (length new_tcs) <> comma
        <+> text "exposed only by casts:"
        <+> int (length [ () | (ms, _, Exposed, _, _) <- fates, exposed_by_cast ms ]) <> comma
        <+> text "pinned binders:" <+> int (sizeVarSet pinned)
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
