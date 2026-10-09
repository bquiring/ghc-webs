-- | One-shot lambdas from webs: if every value of a web is applied at most
-- once, the web's lambdas are one-shot.
--
-- See Note [One-shot lambdas from webs].
module GHC.WebCore.Transform.OneShot
  ( oneShotRound
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.TyCo.Rep
import GHC.Core.Type
import GHC.Core.Coercion ( coercionLKind, coercionRKind )

import GHC.Types.Basic ( OneShotInfo(..) )
import GHC.Types.Demand ( isAtMostOnceDmd )
import GHC.Types.Id
import GHC.Types.Unique ( getKey )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply ( UniqSupply )
import GHC.Types.Web

import GHC.Utils.Outputable

import GHC.WebCore.Traverse ( typeWebs )

import Data.List ( sortOn )

{- Note [One-shot lambdas from webs]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A lambda is one-shot if it is applied at most once.  GHC uses this to float
work into the lambda and to eta-expand through it; it learns it from demand
analysis (a lambda whose consumer calls it at most once) and from the state
hack.  Demand analysis sees the consumer of a lambda only when the lambda is
passed to a known function.  A non-exposed web knows every place its
function values go: the binders they are bound to, and the calls.

A web w's lambdas are one-shot if every value of w is applied at most once:

  * every binder whose type's top arrow (under foralls) is in w is used at
    most once (its demand, from the demand analysis that runs just before
    the early web pipeline, has cardinality at most 1); a value used at most
    once is applied at most once;
  * w appears nowhere else a value could be shared without a binder of
    that type: not in a data constructor's field or any other type
    constructor's argument, not in a type argument (a polymorphic function
    could share it as a value of type a), and not in a coercion.  An arrow
    of w as the argument or result of another arrow is a parameter (a
    binder) or the result of a call (bound, or called directly).

Only in the early run: the demands are fresh there.  A web transformation
that runs later may move code, but does not apply a value more often.
Wrongly marking a lambda one-shot would lose sharing, not change results.
-}

data Info = Info
  { i_lams    :: [Id]
  , i_shared  :: Bool    -- ^ some binder of the web is used more than once
  , i_hidden  :: Bool }  -- ^ the web appears in data, a type argument or a coercion

noInfo :: Info
noInfo = Info [] False False

plusInfo :: Info -> Info -> Info
plusInfo a b = Info (i_lams a ++ i_lams b) (i_shared a || i_shared b) (i_hidden a || i_hidden b)

note :: WebId -> Info -> UniqFM WebId Info -> UniqFM WebId Info
note w i m | isPlaceholderWeb w = m
           | otherwise          = addToUFM_C plusInfo m w i

analyse :: CoreProgram -> UniqFM WebId Info
analyse binds = foldr go_bind emptyUFM binds
  where
    go_bind bind acc = foldr (\(b, e) -> go_bndr b . go e) acc (flattenBinds [bind])

    go :: CoreExpr -> UniqFM WebId Info -> UniqFM WebId Info
    go expr acc = case expr of
      WebLam w p e -> note w (noInfo { i_lams = [p] }) (go_bndr p (go e acc))
      Lam b e      -> go_bndr b (go e acc)
      WebApp _ f a -> go f (go a acc)
      App f a      -> go f (go a acc)
      Let bind e   -> go_bind bind (go e acc)
      Case e b ty alts
        -> go e $ go_bndr b $ go_top ty $
           foldr (\(Alt _ bs rhs) a -> foldr go_bndr (go rhs a) bs) acc alts
      Cast e co    -> go e (hide (coWebs co) acc)
      Tick _ e     -> go e acc
      Type t       -> hide (typeWebs t) acc
      Coercion co  -> hide (coWebs co) acc
      _            -> acc

    -- A binder: its top arrow is used as often as the binder; the rest of
    -- its type is checked as a type in an arrow position
    go_bndr b acc
      | isId b
      , (_, ty) <- splitForAllTyCoVars (idType b)
      , FunTy { ft_web = w } <- ty
      = note w (noInfo { i_shared = not (isAtMostOnceDmd (idDemandInfo b)) }) (go_top ty acc)
      | isId b    = go_top (idType b) acc
      | otherwise = acc

    -- A type in a value position: arrows directly under arrows are fine;
    -- anything under a type constructor or an application is hidden
    go_top ty acc = case ty of
      ForAllTy _ t -> go_top t acc
      FunTy { ft_arg = a, ft_res = r } -> go_top a (go_top r acc)
      _            -> hide (typeWebs ty) acc

    hide ws acc = foldr (\w -> note w (noInfo { i_hidden = True })) acc (nonDetEltsUniqSet ws)

    coWebs co = typeWebs (coercionLKind co) `unionUniqSets` typeWebs (coercionRKind co)

data Verdict = OneShot | NotOneShot String

instance Outputable Verdict where
  ppr OneShot        = text "one-shot"
  ppr (NotOneShot r) = text "not one-shot" <+> parens (text r)

-- | Mark the lambdas of the webs that qualify one-shot.  Changes no types:
-- one round is enough.
oneShotRound :: Bool -> UniqSupply -> WebSet -> WebSet -> CoreProgram
             -> (Maybe (CoreProgram, WebSet), [(WebId, SDoc, Bool, [Id])])
oneShotRound early _ exposed done binds
  | isEmptyUniqSet todo = (Nothing, dump)
  | otherwise           = (Just (map rw_bind binds, todo), dump)
  where
    verdicts = [ (w, v, i)
               | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList (analyse binds))
               , let w = mkWebId u
               , not (null (i_lams i)), not (w `elementOfUniqSet` done)
               , let v | not early                      = NotOneShot "late run"
                       | w `elementOfUniqSet` exposed   = NotOneShot "exposed"
                       | i_hidden i                     = NotOneShot "in data, a type argument or a coercion"
                       | i_shared i                     = NotOneShot "used more than once"
                       | all is_one_shot (i_lams i)     = NotOneShot "already one-shot"
                       | otherwise                      = OneShot ]
    todo = mkUniqSet [ w | (w, OneShot, _) <- verdicts ]
    dump = [ (w, ppr v, w `elementOfUniqSet` todo, i_lams i) | (w, v, i) <- verdicts ]
    is_one_shot b = idOneShotInfo b == OneShotLam

    rw_bind (NonRec b e) = NonRec b (rw e)
    rw_bind (Rec prs)    = Rec [ (b, rw e) | (b, e) <- prs ]

    rw expr = case expr of
      WebLam w p e
        | w `elementOfUniqSet` todo -> WebLam w (setOneShotLambda p) (rw e)
        | otherwise                 -> WebLam w p (rw e)
      Lam b e      -> Lam b (rw e)
      WebApp w f a -> WebApp w (rw f) (rw a)
      App f a      -> App (rw f) (rw a)
      Let bind e   -> Let (rw_bind bind) (rw e)
      Case e b ty alts -> Case (rw e) b ty [ Alt c bs (rw r) | Alt c bs r <- alts ]
      Cast e co    -> Cast (rw e) co
      Tick t e     -> Tick t (rw e)
      _            -> expr
