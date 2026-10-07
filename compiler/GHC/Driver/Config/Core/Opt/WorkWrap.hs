module GHC.Driver.Config.Core.Opt.WorkWrap
  ( initWorkWrapOpts
  ) where

import GHC.Prelude ( Maybe(Nothing) )

import GHC.Driver.Config (initSimpleOpts)
import GHC.Driver.DynFlags

import GHC.Core.FamInstEnv
import GHC.Core.Opt.WorkWrap
import GHC.Unit.Types
import GHC.Types.Var.Env ( emptyVarEnv )

initWorkWrapOpts :: Module -> DynFlags -> FamInstEnvs -> WwOpts
initWorkWrapOpts this_mod dflags fam_envs = MkWwOpts
  { wo_fam_envs          = fam_envs
  , wo_simple_opts       = initSimpleOpts dflags
  , wo_cpr_anal          = gopt Opt_CprAnal dflags
  , wo_module            = this_mod
  , wo_unlift_strict     = gopt Opt_WorkerWrapperUnlift dflags
  , wo_fun_results       = gopt Opt_WorkerWrapperFunResults dflags
  , wo_pedantic_bottoms  = gopt Opt_PedanticBottoms dflags
  , wo_dicts_strict      = gopt Opt_DictsStrict dflags
  , wo_dmd_unbox_width   = dmdUnboxWidth dflags
  , wo_max_worker_args   = maxWorkerArgs dflags
  , wo_fr_wrappers       = emptyVarEnv
  , wo_call_lams         = Nothing
  , wo_res_uses          = Nothing
  }
