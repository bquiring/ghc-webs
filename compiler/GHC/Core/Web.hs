

module GHC.Core.Web (

    Web(..),
    pprWeb
) where

import GHC.Prelude
import GHC.Utils.Outputable
import Data.Data

data Web = WBorder 
         | W Int
    deriving (Eq, Data, Ord)

pprWeb WBorder = text "{BORDER}"
pprWeb (W n) = text ("{" ++ (show n) ++ "}")