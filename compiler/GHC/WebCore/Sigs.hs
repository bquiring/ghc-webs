-- | Exposed signatures of global entities, for the web pipeline.
--
-- See Note [Exposed webs].
module GHC.WebCore.Sigs
  ( WebSigs(..)
  , emptyWebSigs
  , lookupGlobalIdSig, lookupDataConSig, lookupAxiomSig
  , addGlobalIdSig, addDataConSig, addAxiomSig
  , addExposedWebs
  , pprWebSigs
    -- * Hidden fields
  , FieldTys, fieldTys, sigFields
  ) where

import GHC.Prelude

import GHC.Core.Coercion.Axiom
import GHC.Core.DataCon
import GHC.Core.TyCon ( TyCon )
import GHC.Core.TyCo.Rep ( Type(..), Scaled(..), scaledThing )
import GHC.Core.TyCo.Subst ( substTysWith )
import GHC.Types.Var ( TyVar, VarBndr(..) )
import GHC.Core.TyCo.Ppr ( pprType )

import GHC.Types.Id
import GHC.Types.Unique ( getUnique )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Types.Web

import GHC.Utils.Outputable

{- Note [Exposed webs]
~~~~~~~~~~~~~~~~~~~~~~
Some entities have types that are fixed outside the module being compiled:

  * global Ids: imported functions, data constructor workers and wrappers,
    class method selectors, primops, ...
  * data constructors, whose types are used when matching on them
  * coercion axioms (newtypes, type families, data families)

Annotation gives each such entity one /exposed signature/: a copy of its type
with fresh webs.  Every use of the entity shares the webs of that signature, so
the webs of the module's own functions are linked to them (for example, a
function stored in a data constructor field is linked to the function taken
out of it by a case).

The webs of exposed signatures are /exposed/, as are the webs in the types of
exported top-level binders, since those types are visible to other modules.
The same goes for local top-level binders whose unfoldings or rules may reach
the interface file (ws_interface_ids): Tidy exposes the Ids mentioned in the
unfoldings of exported Ids, and in RULES.  Those unfoldings are unannotated
Core that a transformation does not rewrite, so the types of the Ids they
mention must not change.
Every web involved in a coercion axiom is exposed.  A web class that contains
an exposed web must keep its calling convention.

How the signatures are used:

  * Global Ids: annotation replaces each occurrence of a global Id with a clone
    (same Name and Unique) whose type is the exposed signature.  Erasure puts
    the original Id back.

  * Coercion axioms: annotation replaces the CoAxiom in an AxiomCo with a clone
    (same Name and Unique) whose branches have exposed signatures, so
    coercionKind produces web-annotated types.  Erasure puts the original
    CoAxiom back.

  * Data constructors: Web Lint (GHC.WebCore.Lint.lintCoreAlt) reads the type
    of a data constructor from ws_dcs.  A data constructor's worker Id gets the
    same signature as the data constructor itself.  For a type whose fields
    are hidden, only the constructor's own arrows are exposed: Note [Hidden
    fields].
-}

{- Note [Hidden fields]
~~~~~~~~~~~~~~~~~~~~~~~
What other modules see of this one is its export signature.  A data type's
fields are part of it only if one of its constructors or record fields is
exported: a type defined here whose constructors are not exported (local,
or exported abstractly) has /hidden fields/, even if exported functions
mention it by name.  The webs inside a hidden field's type are internal, so
the module's functions stored in such a field, e.g. w in

    data T = T Int (T ->{w} Int)

can change their calling convention.  The webs of the constructor's own
arrows stay exposed: its arity is fixed.

A constructor that occurs in Core the transformations do not rewrite (the
RULES, and stable unfoldings in the early run) keeps its fields exposed, as
do newtypes (their axioms are exposed), classes, families, and types with
existentials or GADT constructors.

So does a type that an unsafe coercion relates to another (a type argument
of unsafeCoerce or unsafeEqualityProof, Note [Non-parametric functions] in
GHC.WebCore.DataSplit, or a type in a UnivCo), and every type reachable
through its fields: the other side reads the original layout.  Coercing a
hidden-field type whose field web was raised to a type that still expects
the old field was a miscompilation.  Only types written in the coercion are
seen: a polymorphic unsafeCoerce @a @Int, in a function called at a
hidden-field type, gets past this rule (ignored for now; WEBS-BACKLOG.md).

See hiddenFields in GHC.WebCore.Pipeline.
-}

data WebSigs = WebSigs
  { ws_ids     :: VarEnv (Id, Id)
      -- ^ Global Id -> (original Id, clone whose type is the exposed signature)
  , ws_dcs     :: UniqFM DataCon (DataCon, Type)
      -- ^ DataCon -> exposed signature of its 'dataConRepType'
  , ws_axioms  :: UniqFM (CoAxiom Branched) (CoAxiom Branched, CoAxiom Branched)
      -- ^ CoAxiom -> (original axiom, clone whose branches have exposed signatures)
  , ws_exposed :: WebSet
      -- ^ All exposed webs
  , ws_interface_ids :: VarSet
      -- ^ Local top-level Ids whose unfoldings or rules may reach the
      -- interface file: the exported Ids, the Ids free in RULES, and
      -- (transitively) the Ids free in their unfoldings and rules.  Their
      -- types are exposed, and transformations must keep their unfoldings.
  , ws_hidden_fields :: TyCon -> Bool
      -- ^ Types whose fields other modules cannot see: Note [Hidden fields]
  , ws_saturated :: WebSet
      -- ^ Webs never partially applied: the arrows arity raising makes for
      -- a raised product's components (Note [Component demands] in
      -- GHC.WebCore.Transform.ArityRaise)
  }

emptyWebSigs :: WebSigs
emptyWebSigs = WebSigs { ws_ids     = emptyVarEnv
                       , ws_dcs     = emptyUFM
                       , ws_axioms  = emptyUFM
                       , ws_exposed = emptyUniqSet
                       , ws_interface_ids = emptyVarSet
                       , ws_hidden_fields = const False
                       , ws_saturated = emptyUniqSet }

lookupGlobalIdSig :: WebSigs -> Id -> Maybe (Id, Id)
lookupGlobalIdSig sigs v = lookupVarEnv (ws_ids sigs) v

lookupDataConSig :: WebSigs -> DataCon -> Maybe Type
lookupDataConSig sigs dc = snd <$> lookupUFM (ws_dcs sigs) dc

lookupAxiomSig :: WebSigs -> CoAxiom br -> Maybe (CoAxiom Branched, CoAxiom Branched)
lookupAxiomSig sigs ax = lookupUFM_Directly (ws_axioms sigs) (getUnique ax)

addGlobalIdSig :: Id -> Id -> WebSigs -> WebSigs
addGlobalIdSig orig clone sigs
  = sigs { ws_ids = extendVarEnv (ws_ids sigs) orig (orig, clone) }

addDataConSig :: DataCon -> Type -> WebSigs -> WebSigs
addDataConSig dc ty sigs = sigs { ws_dcs = addToUFM (ws_dcs sigs) dc (dc, ty) }

addAxiomSig :: CoAxiom Branched -> CoAxiom Branched -> WebSigs -> WebSigs
addAxiomSig orig clone sigs
  = sigs { ws_axioms = addToUFM (ws_axioms sigs) orig (orig, clone) }

addExposedWebs :: WebSet -> WebSigs -> WebSigs
addExposedWebs ws sigs = sigs { ws_exposed = ws_exposed sigs `unionUniqSets` ws }

pprWebSigs :: WebSigs -> SDoc
pprWebSigs (WebSigs { ws_ids = ids, ws_dcs = dcs, ws_axioms = axs, ws_exposed = exposed })
  = vcat [ text "Exposed global Ids:"
         , nest 2 $ vcat [ ppr v <+> dcolon <+> pprType (idType clone)
                         | (v, clone) <- nonDetEltsUFM ids ]
         , text "Exposed data constructors:"
         , nest 2 $ vcat [ ppr dc <+> dcolon <+> pprType ty
                         | (dc, ty) <- nonDetEltsUFM dcs ]
         , text "Exposed axioms:"
         , nest 2 $ vcat [ ppr ax <+> vcat (map ppr_branch (fromBranches (co_ax_branches clone)))
                         | (ax, clone) <- nonDetEltsUFM axs ]
         , text "Exposed webs:" <+> pprUniqSet ppr exposed ]
  where
    ppr_branch br = sep [ ppr (cab_lhs br), text "~", pprType (cab_rhs br) ]

------------------------------------------------------------------
--      Hidden fields
------------------------------------------------------------------

-- | The field types of a data constructor at the given type arguments
type FieldTys = DataCon -> [Type] -> [Type]

-- | Field types with the webs of the constructor's current signature, for a
-- type with hidden fields (Note [Hidden fields]): a transformation that
-- takes a product apart must give its components those webs, which other
-- transformations may change; otherwise the constructor's own field types
-- (whose arrows have no webs, and whose webs are exposed)
fieldTys :: WebSigs -> FieldTys
fieldTys sigs dc args
  | ws_hidden_fields sigs (dataConTyCon dc)
  , Just sig <- lookupDataConSig sigs dc
  , Just (tvs, fields, _) <- sigFields dc sig
  , length tvs == length args
  = substTysWith tvs args (map scaledThing fields)
  | otherwise
  = map scaledThing (dataConInstArgTys dc args)

-- | A constructor signature's type variables, fields and result
sigFields :: DataCon -> Type -> Maybe ([TyVar], [Scaled Type], Type)
sigFields dc = go []
  where
    go tvs (ForAllTy (Bndr tv _) t) = go (tv : tvs) t
    go tvs t                        = fields (reverse tvs) (dataConRepArity dc) [] t

    fields tvs 0 acc res = Just (tvs, reverse acc, res)
    fields tvs n acc (FunTy { ft_mult = m, ft_arg = a, ft_res = r })
      = fields tvs (n - 1 :: Int) (Scaled m a : acc) r
    fields _ _ _ _ = Nothing
