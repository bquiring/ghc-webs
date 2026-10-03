{-# LANGUAGE NoPolyKinds #-}
module GHC.WebCore where
import {-# SOURCE #-} GHC.Types.Var

data Expr a

type WebCoreBndr = Var

type WebCoreExpr = Expr WebCoreBndr
