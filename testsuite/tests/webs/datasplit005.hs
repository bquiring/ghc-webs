{-# LANGUAGE DeriveGeneric, DefaultSignatures, FlexibleContexts, TypeOperators #-}
-- GHC.Generics' FixityI is used promoted ('PrefixI, in the Constructor
-- instances' SingI axioms, from the exported Either instance): it must not
-- be copied (Note [Types used as kinds])
module Main ( main, Pretty(..) ) where

import GHC.Generics

class Pretty a where
  pretty :: a -> String
  default pretty :: (Generic a, GShow (Rep a)) => a -> String
  pretty = gshow . from

class GShow f where
  gshow :: f p -> String

instance GShow U1 where gshow _ = ""
instance (GShow f, GShow g) => GShow (f :+: g) where
  gshow (L1 x) = gshow x
  gshow (R1 x) = gshow x
instance (GShow f, GShow g) => GShow (f :*: g) where
  gshow (x :*: y) = gshow x ++ " " ++ gshow y
instance Pretty c => GShow (K1 i c) where gshow (K1 x) = pretty x
instance GShow f => GShow (D1 d f) where gshow (M1 x) = gshow x
instance GShow f => GShow (S1 s f) where gshow (M1 x) = gshow x
instance (Constructor c, GShow f) => GShow (C1 c f) where
  gshow m@(M1 x) = conName m ++ fix (conFixity m) ++ " " ++ gshow x
    where fix Prefix = "/prefix"
          fix (Infix _ n) = "/infix" ++ show n

instance Pretty Int where pretty = show
instance Pretty Bool
instance (Pretty a, Pretty b) => Pretty (Either a b)
instance (Pretty a, Pretty b) => Pretty (a, b)

main :: IO ()
main = do
  putStrLn (pretty (Left 1 :: Either Int Bool))
  putStrLn (pretty (Right True :: Either Int Bool))
  putStrLn (pretty (2 :: Int, False))
