-- | Web identifiers.
--
-- See Note [Webs] and the web pipeline in "GHC.WebCore.Pipeline".
module GHC.Types.Web
  ( WebId
  , mkWebId, webIdUnique
  , placeholderWeb, isPlaceholderWeb
  , webUniqueTag
  , WebSet, WebSubst
  ) where

import GHC.Prelude

import GHC.Types.Unique
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Utils.Outputable

import GHC.Utils.Misc ( abstractConstr, mkNoRepType )

import Data.Data ( Data(..) )

{- Note [Webs]
~~~~~~~~~~~~~~
A /web/ is an equivalence class of program points -- value lambdas, value
calls and arrow types -- that the typing rules force to agree.  See "Webs and
Flow-Directed Well-Typedness Preserving Program Transformations" (Quiring, Van
Horn, Reppy, Shivers; PLDI 2025).

Every arrow ('FunTy' and 'FunCo') carries a 'WebId'.  Outside the web pipeline
(GHC.WebCore.Pipeline) that WebId is always 'placeholderWeb', and nothing reads
it: type equality ignores webs.  Inside the pipeline, every term-level arrow
carries a real web, value lambdas are 'WebLam' and value calls are 'WebApp'.
-}

-- | A web.  Two arrows with the same 'WebId' are in the same web.
newtype WebId = WebId Unique
  deriving Eq

instance Data WebId where
  -- don't traverse
  toConstr _   = abstractConstr "WebId"
  gunfold _ _  = error "gunfold"
  dataTypeOf _ = mkNoRepType "WebId"

instance Uniquable WebId where
  getUnique (WebId u) = u

instance Outputable WebId where
  ppr w | isPlaceholderWeb w = text "w_"
        | otherwise          = ppr (getUnique w)   -- Fresh webs have tag 'w'

mkWebId :: Unique -> WebId
mkWebId = WebId

webIdUnique :: WebId -> Unique
webIdUnique (WebId u) = u

-- | The unique supply tag used for fresh webs.
webUniqueTag :: Char
webUniqueTag = 'w'

-- | The web that every arrow carries outside the web pipeline.
-- It uses its own tag, so it can never clash with a fresh web.
placeholderWeb :: WebId
placeholderWeb = WebId (mkUnique 'W' 0)

isPlaceholderWeb :: WebId -> Bool
isPlaceholderWeb w = w == placeholderWeb

type WebSet   = UniqSet WebId
type WebSubst = UniqFM WebId WebId
