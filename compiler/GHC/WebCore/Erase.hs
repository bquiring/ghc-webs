-- | Erasure: map a web-annotated program back to ordinary Core.
module GHC.WebCore.Erase
  ( eraseProgram
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.Coercion.Axiom

import GHC.Types.Web

import GHC.WebCore.Sigs
import GHC.WebCore.Traverse

-- | Erase all webs:
--
--   * 'WebLam' becomes 'Lam' and 'WebApp' becomes 'App'
--   * every web becomes 'placeholderWeb'
--   * clones of global Ids and coercion axioms are replaced by the originals
--     (see Note [Exposed webs] in GHC.WebCore.Sigs)
--
-- The result is ordinary Core, suitable for the rest of the compiler.
eraseProgram :: WebSigs -> CoreProgram -> CoreProgram
eraseProgram sigs = mapWebsProgram eraser
  where
    eraser = WebMapper { wm_web       = const placeholderWeb
                       , wm_axiom     = restore_axiom
                       , wm_global_id = \v -> fst <$> lookupGlobalIdSig sigs v
                       , wm_erase     = True }

    restore_axiom rule = case rule of
      UnbranchedAxiom ax
        | Just (orig, _) <- lookupAxiomSig sigs ax
        -> UnbranchedAxiom (toUnbranchedAxiom orig)
      BranchedAxiom ax i
        | Just (orig, _) <- lookupAxiomSig sigs ax
        -> BranchedAxiom orig i
      _ -> rule
