-- | Renaming: rewrite every web to the representative of its class.
module GHC.WebCore.Rename
  ( renameProgram
  , renameSigs
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.Coercion.Axiom

import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Var.Env
import GHC.Types.Web

import GHC.WebCore.Sigs
import GHC.WebCore.Traverse

import Data.Array ( bounds, listArray )

-- | Rewrite every web of a program to its representative.
-- The 'WebSigs' must already be renamed (see 'renameSigs'), so that axioms
-- and global Ids are replaced by their renamed clones.
renameProgram :: WebSubst -> WebSigs -> CoreProgram -> CoreProgram
renameProgram subst renamed_sigs = mapWebsProgram (renameMapper subst renamed_sigs)

renameMapper :: WebSubst -> WebSigs -> WebMapper
renameMapper subst renamed_sigs
  = WebMapper { wm_web       = renameWeb subst
              , wm_axiom     = rename_axiom
              , wm_global_id = \v -> snd <$> lookupGlobalIdSig renamed_sigs v
              , wm_erase     = False }
  where
    rename_axiom rule = case rule of
      UnbranchedAxiom ax
        | Just (_, ax') <- lookupAxiomSig renamed_sigs ax
        -> UnbranchedAxiom (toUnbranchedAxiom ax')
      BranchedAxiom ax i
        | Just (_, ax') <- lookupAxiomSig renamed_sigs ax
        -> BranchedAxiom ax' i
      _ -> rule

renameWeb :: WebSubst -> WebId -> WebId
renameWeb subst w = lookupWithDefaultUFM subst w w

-- | Rename the webs of the exposed signatures.
renameSigs :: WebSubst -> WebSigs -> WebSigs
renameSigs subst sigs@(WebSigs { ws_ids = ids, ws_dcs = dcs, ws_axioms = axs, ws_exposed = exposed })
  = sigs { ws_ids     = mapVarEnv (\(orig, clone) -> (orig, mapWebsId wm clone)) ids
         , ws_dcs     = mapUFM (\(dc, ty) -> (dc, mapWebsType wm ty)) dcs
         , ws_axioms  = mapUFM (\(orig, clone) -> (orig, rename_ax clone)) axs
         , ws_exposed = mapUniqSet (renameWeb subst) exposed }
  where
    -- Only the webs change, so types need no other mapping
    wm = WebMapper { wm_web       = renameWeb subst
                   , wm_axiom     = id
                   , wm_global_id = const Nothing
                   , wm_erase     = False }

    rename_ax ax
      = let MkBranches arr = co_ax_branches ax
            branches' = [ br { cab_lhs = map (mapWebsType wm) (cab_lhs br)
                             , cab_rhs = mapWebsType wm (cab_rhs br) }
                        | br <- fromBranches (co_ax_branches ax) ]
        in ax { co_ax_branches = MkBranches (listArray (bounds arr) branches') }
