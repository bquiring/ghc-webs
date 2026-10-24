{-# LANGUAGE DataKinds, GADTs, KindSignatures #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}
-- Note [Copies of unpacked fields] in GHC.WebCore.DataSplit: lsp-types'
-- records unpack a field whose constructor has a context, so the worker
-- takes a dictionary; such a type is not copied
module Main (main) where

import GHC.TypeLits ( KnownSymbol, Symbol, symbolVal )
import Data.Proxy ( Proxy(..) )

data AString (s :: Symbol) where
  AString :: KnownSymbol s => AString s

name :: forall s. AString s -> String
name a@AString = symbolVal (proxy a)
  where proxy :: AString s -> Proxy s
        proxy _ = Proxy

data Report = Report !(AString "unchanged") !Int Bool

mk :: Int -> Report
mk i = Report AString i (even i)
{-# NOINLINE mk #-}

size :: Report -> Int
size (Report k n b) = if b then n + length (name k) else n
{-# NOINLINE size #-}

main :: IO ()
main = print (sum (map (size . mk) [1 .. 100]))
