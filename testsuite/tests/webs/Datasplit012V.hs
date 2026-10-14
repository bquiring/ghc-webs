-- The type of datasplit012, in its own module (as Var is in the solver):
-- its derived (==) reaches Main as an unfolding
module Datasplit012V (V(..)) where

data V q = P q | F q | S q
  deriving Eq
