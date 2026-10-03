
import GHC.Core
import GHC.WebCore

erase :: WebCore.Expr b -> Core.Expr b
erase WebCore.Var x = Core.Var x
erase WebCore.Lit lit = Core.Lit lit
erase WebCore.App w f arg = Core.App (erase f) (erase arg)
erase WebCore.Lam w x e = Core.Lam x (erase e)
erase WebCore.Let (NonRec x e) e' = Core.Let (NonRec x e) e'
erase WebCore.Let (Rec binds) e' = Core.Let (Rec (map (\ (x, e) . (x, erase e)) binds)) e'
erase WebCore.Case e x ty cases = Core.Case (erase e) x (eraseTy ty) cases...
erase WebCore.Cast e coer = Core.Cast (erase e) coer...
erase WebCore.Tick ct e = Core.Tick ct e
erase WebCore.Type ty = Core.Type (eraseTy ty)
erase WebCore.Coercion coer = Core.Coercion coer...

eraseTy :: WebCore.Type -> Core.Type


data Expr b
  = Var   Id
  | Lit   Literal
  | App   Web (Expr b) (Arg b)
  | Lam   Web b (Expr b)
  | Let   (Bind b) (Expr b)
  | Case  (Expr b) b Type [Alt b]   -- See Note [Case expression invariants]
                                    -- and Note [Why does Case have a 'Type' field?]
  | Cast  (Expr b) CoercionR        -- The Coercion has Representational role
  | Tick  CoreTickish (Expr b)
  | Type  Type
  | Coercion Coercion
