{-# LANGUAGE LambdaCase #-}

-- | Compiling a program's modules together as one Core program
-- (-fcore-webs-chunk); see Note [Chunks]
module GHC.WebCore.Chunk
  ( chunkMake
  ) where

import GHC.Prelude

import GHC ( Target, setTargets, LoadHowMuch(..), getModSummary, setSessionDynFlags )
import GHC.Driver.Make ( depanal, load', noIfaceCache )
import GHC.Driver.Messager ( batchMsg )
import GHC.Types.Error ( mkUnknownDiagnostic )
import GHC.Core.Opt.Monad ( getModule )
import GHC.Unit.Module.Graph ( ModuleGraph, mapMG, mgModSummaries, mgModSummaries', mkModuleGraph, mkNodeKey
                              , ModuleGraphNode(..), ModuleNodeInfo(..), ModuleNodeEdge(..), msKey )
import GHC.Types.Avail ( AvailInfo(..) )
import System.Directory ( doesFileExist, copyFile )
import GHC.Driver.DynFlags
import GHC.Driver.Env
import GHC.Driver.Main ( hscSimplify, hscTidy, hscGenHardCode )
import GHC.Driver.Monad
import GHC.Driver.Phases ( StopPhase(..) )
import GHC.Driver.Pipeline ( compileFile )
import GHC.Driver.Pipeline.Execute ( joinObjectFiles )
import GHC.Driver.Plugins
import GHC.Driver.Errors.Types ()

import GHC.Core
import GHC.Core.FVs ( mkRuleInfo, exprsSomeFreeVars, orphNamesOfExprs )
import GHC.Core.Lint ( displayLintResults )
import GHC.Driver.Config.Core.Lint ( lintCoreBindings )
import GHC.Core.Ppr ( pprCoreBindings )
import GHC.Types.Var.Set ( mkVarSet, elemVarSet )
import GHC.Types.Unique.Set ( nonDetEltsUniqSet, isEmptyUniqSet )
import GHC.Core.Opt.Pipeline.Types ( CoreToDo(..) )
import GHC.Core.Opt.Simplify ( SimplifyOpts(..) )
import GHC.Core.Opt.Simplify.Env ( SimplMode(..) )
import GHC.Types.Basic ( CompilerPhase(..) )
import GHC.Core.InstEnv ( emptyInstEnv, filterInstEnv, is_dfun )
import GHC.Core.FamInstEnv ( famInstAxiom )
import GHC.Iface.Make ( mkPartialIface, mkFullIface )
import GHC.Iface.Load ( writeIface, flagsToIfCompression )

import GHC.Stg.EnforceEpt.TagSig ( StgCgInfos )
import GHC.StgToCmm.Types ( CmmCgInfos )
import GHC.Types.Name ( getName )
import GHC.Core.FamInstEnv ( extendFamInstEnvList, emptyFamInstEnv )

import GHC.Linker.Static ( linkBinary )

import GHC.Types.Id
import GHC.Types.Id.Info
import GHC.Types.Name ( getOccString, nameModule_maybe, localiseName )
import GHC.Types.Name.Set ( mkNameSet, elemNameSet, nameSetElemsStable, filterNameSet, extendNameSet )
import GHC.Iface.Syntax ( ifName, ifaceDeclImplicitBndrs, freeNamesIfDecl )
import GHC.Unit.Module.ModIface ( mi_decls )
import GHC.Types.Name.Occurrence ( occNameString )
import GHC.Types.TypeEnv ( typeEnvElts )
import GHC.Types.TyThing ( TyThing(..) )
import GHC.Core.Utils ()
import GHC.Types.Var.Env
import GHC.Types.ForeignStubs
import GHC.Types.Basic ( failed )

import GHC.Unit.Module
import GHC.Unit.Module.ModGuts
import GHC.Unit.Module.ModSummary ( ModSummary(..), ms_location, ms_mod_name, isBootSummary )
import GHC.Unit.Module.Location ( ModLocation(..) )
import GHC.Unit.Module.ModDetails ( ModDetails(..) )
import GHC.Unit.Home.ModInfo ( HomeModInfo(..) )
import GHC.Unit.Home.PackageTable ( hptInternalTableRef, hptCollectDependencies, lookupHpt, addHomeModInfoToHpt )
import GHC.Unit.Module.ModIface ( ModIface )

import GHC.Utils.Logger
import GHC.Utils.Outputable
import GHC.Utils.Error ( withTiming )
import GHC.Utils.Panic
import GHC.Data.Maybe ( fromMaybe, isNothing )
import GHC.Types.Unique.DFM ( mapUDFM )

import Control.Monad
import Data.IORef
import Data.List ( sortOn, isSuffixOf )
import qualified Data.Set as Set
import qualified Data.Map as Map
import GHC.Types.Unique.Supply ( UniqSupply, mkSplitUniqSupply, uniqsFromSupply, splitUniqSupply, listSplitUniqSupply, uniqFromSupply )
import GHC.Core.Subst ( Subst, mkEmptySubst, lookupIdSubst, cloneBndr, cloneBndrs, cloneIdBndr, cloneRecIdBndrs, substTyUnchecked, substCo, substTickish )
import GHC.Types.Var.Env ( mkInScopeSet )
import GHC.Types.Var ( setVarUnique )
import GHC.Types.Web ( webUniqueTag )
import GHC.Types.Unique ( getUnique, getKey )
import System.Exit
import System.FilePath

{- Note [Chunks]
~~~~~~~~~~~~~~~~
With -fcore-webs-chunk, --make compiles a chunk of the program's modules
as one Core program, so that no module boundary inside it exposes a web
(WEBS-CHUNKS.md).  The chunk is every module of the home unit, or the
modules -fcore-webs-chunk-modules=FILE lists (one name per line); the other
modules are compiled as usual.  It works in two steps:

1. Capture.  The modules are compiled as usual, one at a time in dependency
   order, but with a static plugin that, for the chunk's modules, replaces
   the Core pipeline by one simplifier pass in the initial phase (the
   module's own object still needs its compulsory unfoldings inlined:
   levity-polymorphic code panics in code generation otherwise, nofib
   real/cacheprof, puzzle; the initial phase, so that no rule of a later
   phase fires before the merged program's pipeline; a pass without
   case-of-case or inlining left Core that CorePrep cannot compile, an
   argument applied to a join point's let: hledger) and a pass that
   records the ModGuts.  -fforce-recomp makes every chunk module go
   through the pipeline; a module outside the chunk is compiled only when
   out of date, so a build system that compiles one module at a time
   (hadrian) builds those itself and runs --make on the chunk's modules
   only.

   The captured program must be the one the module's interface describes,
   since the other chunk modules refer to it through the interface: so
   the capture comes after the simplifier, and Tidy, when it makes a local
   binder external, keeps its unique (-fcore-webs-chunk-capture,
   opt_keep_uniques in GHC.Iface.Tidy) instead of a fresh one from the name
   cache.  An interface always exposes compulsory unfoldings: in
   hledger-lib, Hledger.Data.Balancing's default methods (generated lenses)
   have compulsory unfoldings that mention the instance methods of its own
   instance, which Tidy made external as $dmaccount_types_$caccount_types;
   the other modules' instances inlined them, and their occurrences had the
   fresh unique, which no captured binder had.  The kept unique wins over a
   name already in the name cache, which an earlier build's interface of
   the module put there (the chunk rebuilt into its output directory;
   allocateGlobalBinderWith in GHC.Iface.Env, chunk007).

   The chunk's modules' interfaces carry no pragmas
   (-fomit-interface-pragmas, set in their summaries): no unfoldings, and no
   arity, strictness, CAF or tag information.  The modules outside the
   chunk compile against them, and then call the chunk's code as unknown
   functions that may refer to CAFs, which is right whatever the merged
   program did to it; and the desugarer's simple optimiser of the other
   chunk modules cannot look through an unfolding and bring in binders that
   only that module's own compilation made up (ShellCheck:
   newFormatterOptions1, floated out of ShellCheck.Interface's
   newFormatterOptions by the last simplifier pass), which the merged
   program does not define.

2. Merge and compile.  The bindings of the chunk's modules become one
   program in dependency order.  A module refers to another's binder
   through a global Id from that module's interface, with the binder's
   unique; every such occurrence (in expressions, stable unfoldings and
   rules) becomes the binder itself.  The roots stay exported, so
   everything else is internal:
     * the whole program (every module, with Main): only Main.main and
       :Main.main;
     * otherwise every exported binder of the chunk's modules, but those
       that -fcore-webs-unused-exports lists (exports used by no module
       outside the chunk; webs-bench/unused-exports.py), and every class
       instance's dictionary.
   The merged program's export list is the union of the roots' (or Main's),
   which decides which types' constructors stay visible (classifyTyCon in
   GHC.WebCore.Pipeline): the modules outside see the chunk's types as the
   interfaces describe them.  The class instances are dropped from mg_insts
   (the merged module has no interface of its own).  The merged ModGuts
   (Main's, or the chunk's last module's, with every module's types, rules
   and bindings) then goes through the full Core pipeline with the command
   line's flags (webs included), Tidy and code generation, into one object
   (<odir>/WebsChunk.o).  A program is linked from it and the objects of
   the modules outside the chunk; the chunk's modules' own objects are not
   used.  For a library, the chunk's object replaces its first module's
   object and the other modules' objects are empty, so that whatever
   collects the modules' objects (Cabal's archive) gets the chunk's code;
   the interfaces are the capture's.

The home package table still describes the captured modules; their rules
are removed from it, or the pipeline would see them twice, once with the
interfaces' global Ids.

Not handled: Template Haskell (the captured modules' code is unoptimised,
but splices run against it, so it works, only slowly), foreign exports of
modules other than Main, hs-boot cycles, per-module OPTIONS_GHC (the
command line's flags apply to the whole chunk), HPC and profiling.
-}

{- Note [Modules below a chunk]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The --make session of a chunk that -fcore-webs-chunk-modules lists also
holds the modules the chunk imports, and the modules they import.  A build
system (hadrian) has built them, one by one or as other chunks, with its
own command lines; the session's flags differ (--make, the chunk's), so
the recompilation check would compile them again ("Flags changed").  That
is wasted work at best; and a module of another chunk compiled again
against that chunk's interfaces, written from its merged program without
the exports it cut (-fcore-webs-unused-exports), fails (GHC's
GHC.Data.Word64Map.Strict re-exports what GHC.Data.Word64Map.Strict.Internal
no longer exports).  So the modules below the chunk whose interfaces exist,
and all of whose imports are such modules, are fixed nodes of the module
graph: their interfaces are loaded, never compiled.  Modules above the
chunk (a Main outside it, chunk002) and modules not built yet are compiled
as before.
-}

-- | The modules below the chunk that are built: fixed (Note [Modules below a chunk])
fixBelow :: (ModuleName -> Bool) -> ModuleGraph -> IO ModuleGraph
fixBelow in_chunk graph = do
  let nodes = mgModSummaries' graph
      edges n = case n of
        ModuleNode es _ -> map edgeTargetKey es
        _               -> []
      by_key = Map.fromList [ (mkNodeKey n, n) | n <- nodes ]
  -- a module node: built and not a chunk module; a package: available
  built <- fmap Map.fromList $ forM nodes $ \n -> case n of
    ModuleNode _ (ModuleNodeCompile ms)
      -> (,) (mkNodeKey n) <$> if in_chunk (ms_mod_name ms) then return False
                               else doesFileExist (ml_hi_file (ms_location ms))
    ModuleNode _ (ModuleNodeFixed {}) -> return (mkNodeKey n, True)
    UnitNode {}                       -> return (mkNodeKey n, True)
    _                                 -> return (mkNodeKey n, False)
  let -- fixable: built, and so is everything below it (the graph with its
      -- boot nodes is acyclic; the map is its own memo)
      fixable = Map.mapWithKey (\k n -> Map.findWithDefault False k built
                                       && all (\d -> Map.findWithDefault True d fixable) (edges n))
                               by_key
      fix n = case n of
        ModuleNode es (ModuleNodeCompile ms)
          | Map.findWithDefault False (mkNodeKey n) fixable
          -> ModuleNode es (ModuleNodeFixed (msKey ms) (ms_location ms))
        _ -> n
  return (mkModuleGraph (map fix nodes))

-- | --make with -fcore-webs-chunk: see Note [Chunks]
chunkMake :: [Target] -> Ghc ()
chunkMake targets = do
  hsc_env0 <- getSession
  let dflags0 = hsc_dflags hsc_env0
      logger  = hsc_logger hsc_env0
      odir    = fromMaybe "." (objectDir dflags0)
      capdir  = odir </> "webs-chunk-modules"
  -- The chunk: the modules -fcore-webs-chunk-modules lists, or all of them
  listed <- liftIO $ case websChunkModules dflags0 of
    Nothing -> return Nothing
    Just f  -> Just . Set.fromList . concatMap words . lines <$> readFile f
  let in_chunk m = maybe True (moduleNameString m `Set.member`) listed

  ref <- liftIO (newIORef [])
  let capture = CoreDoPluginPass "webs chunk: capture" $ \g ->
                  do { liftIO (modifyIORef' ref (g :)); return g }
      -- the module's own code still needs the compulsory unfoldings
      -- inlined (levity-polymorphic code cannot be compiled otherwise):
      -- one simplifier pass in the initial phase, before the capture, so
      -- that the captured program is the one the module's interface
      -- describes
      lastSimpl todos = [ CoreDoSimplify (gentle o)
                        | CoreDoSimplify o <- take 1 (reverse [ t | t@CoreDoSimplify {} <- concatMap flat todos ]) ]
      gentle o = o { so_mode = (so_mode o) { sm_phase = InitialPhase, sm_names = ["Chunk capture"] } }
      flat t = case t of { CoreDoPasses ts -> concatMap flat ts; _ -> [t] }
      plugin  = defaultPlugin
        { installCoreToDos = \_ todos -> do
            { m <- getModule
            ; return (if in_chunk (moduleName m) then lastSimpl todos ++ [capture] else todos) }
        , pluginRecompile  = purePlugin }
      cap_dflags = dflags0
                     { outputFile_  = Nothing
                     , ghcLink      = NoLink
                     , parMakeCount = Just (ParMakeThisMany 1) }
      -- the chunk's modules: compiled again (to be captured), interfaces
      -- without pragmas (Note [Chunks]), their dumps out of the way; the
      -- modules outside the chunk only when out of date (a build system's,
      -- hadrian's, already built)
      chunk_flags d = (d `gopt_set` Opt_ForceRecomp
                         `gopt_set` Opt_OmitInterfacePragmas `gopt_set` Opt_CoreWebsChunkCapture
                         `gopt_unset` Opt_ExposeAllUnfoldings)
                        { dumpDir = Just capdir }
  _ <- setSessionDynFlags cap_dflags
  modifySession $ \e ->
    e { hsc_plugins = (hsc_plugins e)
          { staticPlugins = StaticPlugin (PluginWithArgs plugin []) True
                            : staticPlugins (hsc_plugins e) } }
  setTargets targets
  graph0 <- depanal [] False
  let graph = mapMG (\ms -> if in_chunk (ms_mod_name ms)
                            then ms { ms_hspp_opts = chunk_flags (ms_hspp_opts ms) } else ms) graph0
      summaries = [ ms | ms <- mgModSummaries graph, isBootSummary ms == NotBoot ]
  -- Note [Modules below a chunk]
  fixed_graph <- liftIO $ if isNothing listed then return graph else fixBelow in_chunk graph
  ok <- withTiming logger (text "Webs chunk: capture") (const ()) $
          load' noIfaceCache LoadAllTargets mkUnknownDiagnostic (Just batchMsg) fixed_graph
  when (failed ok) $ liftIO (exitWith (ExitFailure 1))
  gutss <- reverse <$> liftIO (readIORef ref)
  when (null gutss) $
    liftIO $ throwGhcExceptionIO (CmdLineError "-fcore-webs-chunk: no module in the chunk")

  -- The pipeline for the merged program: the command line's flags, no
  -- capture plugin, and no rules from the home package table
  hsc_env1 <- getSession
  let hpt = hsc_HPT hsc_env1
  liftIO $ modifyIORef' (hptInternalTableRef hpt) $
    mapUDFM (\hmi -> hmi { hm_details = (hm_details hmi) { md_rules = [], md_anns = [] } })
  let hsc_env = hscSetFlags dflags0 $
                hsc_env1 { hsc_plugins = hsc_plugins hsc_env0 }
      main_name = mainModuleNameIs dflags0
      main_guts = [ g | g <- gutss, moduleName (mg_module g) == main_name ]
      -- The whole program: only main stays exported.  Otherwise every
      -- export of the chunk's modules (but the listed unused ones), and
      -- every instance, is a root
      whole = isNothing listed && not (null main_guts)
      base_guts = head (main_guts ++ reverse gutss)
      outside = [ ms | ms <- summaries, not (in_chunk (ms_mod_name ms)) ]
  unused <- liftIO $ readUnusedExportsAll dflags0
  ms <- getModSummary (mg_module base_guts)
  us_merge <- liftIO (mkSplitUniqSupply webUniqueTag)
  us_clone <- liftIO (mkSplitUniqSupply webUniqueTag)
  let merged0 = mergeGuts us_merge dflags0 whole unused base_guts gutss
      merged  = merged0 { mg_binds = cloneLocals us_clone (mg_binds merged0) }
  liftIO $ do
    putDumpFileMaybe logger Opt_D_dump_webs_stats "Webs chunk: modules" FormatText $
      vcat [ text "Modules:" <+> int (length gutss)
           , text "Outside the chunk:" <+> int (length outside)
           , text "Bindings:" <+> int (length (bindersOfBinds (mg_binds merged)))
           , text "Exported:" <+> int (length [ b | b <- bindersOfBinds (mg_binds merged), isExportedId b ]) ]
    -- Occurrences the merge did not reach: global Ids of the chunk's
    -- modules that are not one of its binders
    let bound   = mkVarSet (bindersOfBinds (mg_binds merged))
        chunk_m = Set.fromList (map mg_module gutss)
        stray   = [ v | v <- nonDetEltsUniqSet (exprsSomeFreeVars isId (concatMap rhssOfBind (mg_binds merged)
                                                   ++ concatMap unfOf (bindersOfBinds (mg_binds merged))))
                      , isGlobalId v, not (isImplicitId v), not (v `elemVarSet` bound)
                      , Just m <- [nameModule_maybe (idName v)], m `Set.member` chunk_m ]
        unfOf b = case realIdUnfolding b of
                    CoreUnfolding { uf_tmpl = t } -> [t]
                    DFunUnfolding { df_args = as } -> as
                    _ -> []
    unless (null stray) $
      let strays = mkVarSet stray
          holders = [ (b, nameModule_maybe (idName b)) | (b, e) <- flattenBinds (mg_binds merged)
                    , not (isEmptyUniqSet (exprsSomeFreeVars (`elemVarSet` strays) (e : unfOf b))) ]
          -- the captured binders of the same name, with their uniques
          same_occ v = [ (b, getUnique b) | b <- bindersOfBinds (mg_binds merged0)
                       , getOccString b == getOccString v
                         || ('_' : getOccString b) `isSuffixOf` getOccString v ]
      in pprPanic "-fcore-webs-chunk: occurrences the merge missed"
           (ppr [ (v, getUnique v, nameModule_maybe (idName v), same_occ v) | v <- stray ]
            $$ text "in" <+> ppr holders)
    -- Core Lint on the merged program, before the pipeline, with -dcore-lint
    when (gopt Opt_DoCoreLinting dflags0) $
      displayLintResults logger True (text "the merged program (-fcore-webs-chunk)")
        (pprCoreBindings (mg_binds merged))
        (lintCoreBindings dflags0 (CoreDoPluginPass "webs chunk: merge" return) [] (mg_binds merged))
    simpl <- hscSimplify hsc_env [] merged
    (cgguts, details) <- hscTidy hsc_env simpl
    let location = ms_location ms
        base     = odir </> "WebsChunk"
    (asm, mb_stub, foreign_files, stg_infos, cmm_infos) <-
      hscGenHardCode hsc_env cgguts location (base <.> "s")
    -- The chunk's modules' interfaces, from the merged program (Note
    -- [Interfaces of a chunk])
    -- The merged module's first: the others' unfoldings mention the
    -- binders Tidy made external there, and fingerprinting them looks them
    -- up in its interface in the home package table
    let homedRules = map (homeRule (Set.fromList (map mg_module gutss)) (mg_module base_guts))
                         (md_rules details)
    unless whole $
      forM_ (base_guts : filter ((/= mg_module base_guts) . mg_module) gutss) $ \g ->
        case [ m | m <- summaries, ms_mod_name m == moduleName (mg_module g) ] of
          m : _ -> do
            let rules = [ r | r <- homedRules, ru_origin r == mg_module g ]
            iface <- writeChunkIface hsc_env details rules stg_infos cmm_infos (mergedExports dflags0 unused g) m g
            mb <- lookupHpt hpt (moduleName (mg_module g))
            forM_ mb $ \hmi -> addHomeModInfoToHpt (hmi { hm_iface = iface }) hpt
          []    -> return ()
    unless (null foreign_files) $
      throwGhcExceptionIO (CmdLineError "-fcore-webs-chunk: foreign files are not supported")
    let compile src o = do
          let e = hscSetFlags (dflags0 { outputFile_ = Just o, ghcLink = NoLink }) hsc_env
          r <- compileFile e NoStop (src, Nothing)
          maybe (throwGhcExceptionIO (CmdLineError ("-fcore-webs-chunk: cannot compile " ++ src)))
                return r
    obj  <- compile asm (base <.> "o")
    objs <- case mb_stub of
      Nothing   -> return [obj]
      Just stub -> do { s <- compile stub (base ++ "_stub" <.> "o"); return [obj, s] }
    let program = ghcLink dflags0 == LinkBinary && any ((== main_name) . ms_mod_name) summaries
    -- A program: the chunk's object instead of its modules' objects
    when program $ do
      pkgs <- map snd . Set.toList <$> hptCollectDependencies hpt
      let others = [ ml_obj_file (ms_location m) | m <- outside ]
      linkBinary logger (hsc_tmpfs hsc_env) dflags0 (hsc_unit_env hsc_env) (objs ++ others) pkgs
    -- A library: the chunk's object becomes its first module's, and the
    -- other modules' objects are empty, so that whatever collects the
    -- modules' objects (Cabal's archive) collects the chunk's code
    unless program $ do
      let chunk_objs = [ ml_obj_file (ms_location m) | m <- summaries, in_chunk (ms_mod_name m) ]
          empty_s    = base ++ "_empty" <.> "s"
      writeFile empty_s ""
      empty <- compile empty_s (base ++ "_empty" <.> "o")
      case chunk_objs of
        first : rest -> do
          joinObjs hsc_env objs first
          mapM_ (copyFile empty) rest
        [] -> return ()

{- Note [Merging the chunk's modules]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The captured modules' programs come after a simplifier pass (Note
[Chunks]), and the binders the simplifier makes have uniques that repeat
from one module to the next (hledger-lib: Core Lint saw f_X1, v_B3, ... in
many modules, and the merged program's first simplifier pass applied one
module's function to another's arguments: applyTypeToArgs).  So in the
merge every top-level binder but the roots (whose uniques are the
renamer's, unique in the program) gets a fresh unique, and occurrences are
resolved per module: a local Id is the module's own binder, looked up in
its own table; a global Id with a chunk module's name is that module's
binder, looked up by module and unique.  By module, unit included: hledger's
executable and library both have a module Paths_hledger, and the
executable's chunk took the library's Paths_hledger.main_main (a binder
the library chunk's interface exposes) for one of its own.  Local binders may still repeat
uniques across modules: their scopes are disjoint, but once the merged
program's simplifier inlines across what were module boundaries, one
shadows another, which the web passes did not survive (dhall: Data.Data's
gmapMp for Dhall.Syntax.Import's File applied a variable eta_B0 of
another module's).  So every local binder gets a fresh unique too
(cloneLocals).
-}

{- Note [Interfaces of a chunk]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The capture's interfaces of the chunk's modules carry no pragmas (Note
[Chunks]), so a module outside cannot inline anything of the chunk, nor
know an export's arity: ShellCheck's library as a chunk, used by its
executable, ran 1.8% more instructions than without chunks.  So once the
merged program is compiled, every chunk module M gets its interface again,
from the merged program: mkIface_ keeps the declarations of the names of
M, so the merged program's tidied ModDetails (all its types and
externally visible Ids, with their final types, IdInfo and unfoldings) is
given whole, with the instances whose dictionary function is M's and M's
exports; the code generator's information (CAF, LFInfo) is the merged
object's.

Interfaces that refer to each other's names both ways cannot be
fingerprinted one at a time: fingerprinting a declaration looks up the
names it mentions in their modules' interfaces in the home package table.
So the merged program has no external names but the roots: every other
top-level binder loses its module in the merge (localiseName; ShellCheck:
an unfolding exposed ShellCheck.Analytics.verify, not exported, and
fingerprinting another module's interface looked for it in Analytics's
capture interface: lookupVers1).  The binders Tidy makes external for the
unfoldings, and the data types data splitting made, then all belong to the
merged module (the chunk's last module, or Main), whose interface
declares them.  The usages and
dependencies are the capture's of M.

The merged program's rules (Tidy's: those whose left-hand side mentions
external names only, SPECIALISE and specialiser rules among them) go to
the interfaces too, or an importer loses the chunk's specialisations
(homeRule).  A rule goes where an importer that can use it has loaded the
interface anyway: the module of its function if a chunk module's (a root),
else of a chunk module's name on its left-hand side (a type: a
specialisation of an imported function), and only else the module that
made it, or the merged module.  Its orphanhood is recomputed for that
module: an orphan is only seen by importers that list the module as an
orphan module.  The merged module's
interface is written first, and replaces the capture's in the home package
table: the others' unfoldings mention its binders, and fingerprinting
them looks them up there (lookupVers1 panicked); its own declarations
mention the other modules' exports only, which the capture's interfaces
have.

The modules outside the chunk compiled in the same --make were compiled
against the capture's interfaces; the new ones are for later builds (a
library's dependents).
-}

-- | Write a chunk module's interface from the merged program (Note
-- [Interfaces of a chunk]); also returns it
writeChunkIface :: HscEnv -> ModDetails -> [CoreRule] -> Maybe StgCgInfos -> Maybe CmmCgInfos
                -> [AvailInfo] -> ModSummary -> ModGuts -> IO ModIface
writeChunkIface hsc_env details rules stg_infos cmm_infos exports ms g = do
  let this    = mg_module g
      ours n  = nameModule_maybe n == Just this
      det     = details { md_exports   = exports
                        , md_insts     = filterInstEnv (ours . getName . is_dfun) (md_insts details)
                        , md_fam_insts = filter (ours . getName . famInstAxiom) (md_fam_insts details)
                        , md_rules     = rules
                        , md_anns      = []
                        , md_complete_matches = mg_complete_matches g }
      dflags  = hsc_dflags hsc_env
  -- Every name of this module that a declaration's unfolding mentions
  -- must be declared too, or fingerprinting panics; say which
  let declared = mkNameSet [ getName t | t <- typeEnvElts (md_types det), ours (getName t) ]
      undeclared = [ (getName v, n)
                   | AnId v <- typeEnvElts (md_types det), ours (getName v)
                   , Just tmpl <- [maybeUnfoldingTemplate (realIdUnfolding v)]
                   , w <- nonDetEltsUniqSet (exprsSomeFreeVars isId [tmpl])
                   , let n = idName w, ours n, not (n `elemNameSet` declared) ]
  unless (null undeclared) $
    pprPanic "-fcore-webs-chunk: an interface mentions undeclared names" (ppr this <+> ppr undeclared)
  partial <- mkPartialIface hsc_env [] det ms [] g
  let decls   = mi_decls partial
      known   = Set.fromList (map (getOccString . ifName) decls
                              ++ map occNameString (concatMap ifaceDeclImplicitBndrs decls))
      missing = [ (ifName d, n) | d <- decls, n <- nameSetElemsStable (freeNamesIfDecl d)
                , ours n, getOccString n `Set.notMember` known ]
  unless (null missing) $
    pprPanic "-fcore-webs-chunk: interface declarations mention undeclared names"
      (ppr this <+> ppr missing)
  iface   <- mkFullIface hsc_env partial stg_infos cmm_infos NoStubs []
  writeIface (hsc_logger hsc_env) (targetProfile dflags) (flagsToIfCompression dflags)
             (ml_hi_file (ms_location ms)) iface
  return iface

-- | The chunk module whose interface carries a rule of the merged
-- program, and the rule's orphanhood there (Note [Interfaces of a chunk]):
-- the module of its function if a chunk module's, else of the least name
-- of a chunk module on its left-hand side, else where it was made if a
-- chunk module, else the merged module
homeRule :: Set.Set Module -> Module -> CoreRule -> CoreRule
homeRule _ _ r@BuiltinRule {} = r
homeRule chunk base r@Rule { ru_fn = fn, ru_args = args, ru_origin = origin } =
  r { ru_origin = home, ru_orphan = chooseOrphanAnchor (filterNameSet ((== Just home) . nameModule_maybe) lhs) }
  where
    lhs  = extendNameSet (orphNamesOfExprs args) fn
    ofChunk n = [ m | Just m <- [nameModule_maybe n], m `Set.member` chunk ]
    home = case ofChunk fn of
      m : _ -> m
      []    -> case sortOn (\(m, n) -> (moduleNameString (moduleName m), getOccString n))
                       [ (m, n) | n <- nameSetElemsStable lhs, m <- ofChunk n ] of
        (m, _) : _ -> m
        []         -> if origin `Set.member` chunk then origin else base

-- | A chunk module's exports, but the unused ones (Note [Chunks])
mergedExports :: DynFlags -> Set.Set (String, String) -> ModGuts -> [AvailInfo]
mergedExports _ unused g = [ a | a <- mg_exports g, keep a ]
  where keep (Avail n) = (moduleNameString (moduleName (mg_module g)), getOccString n) `Set.notMember` unused
        keep _         = True

-- | Every local binder gets a fresh unique (Note [Merging the chunk's
-- modules]); the top-level binders stay as they are
cloneLocals :: UniqSupply -> CoreProgram -> CoreProgram
cloneLocals us0 binds = zipWith top (listSplitUniqSupply us0) binds
  where
    subst0 = mkEmptySubst (mkInScopeSet (mkVarSet (bindersOfBinds binds)))
    top us (NonRec b e) = NonRec b (clone subst0 us e)
    top us (Rec prs)    = Rec [ (b, clone subst0 u e) | ((b, e), u) <- zip prs (listSplitUniqSupply us) ]

    clone :: Subst -> UniqSupply -> CoreExpr -> CoreExpr
    clone s us e = case e of
      Var v       -> lookupIdSubst s v
      Lit l       -> Lit l
      App f a     -> let (u1, u2) = splitUniqSupply us in App (clone s u1 f) (clone s u2 a)
      Lam b x     -> let (u1, u2) = splitUniqSupply us
                         (s', b') = cloneBndr s (uniqFromSupply u1) b
                     in Lam b' (clone s' u2 x)
      Let (NonRec b r) x ->
        let (u1, u23) = splitUniqSupply us; (u2, u3) = splitUniqSupply u23
            (s', b')  = cloneIdBndr s u1 b
        in Let (NonRec b' (clone s u2 r)) (clone s' u3 x)
      Let (Rec prs) x ->
        let (u1, u23) = splitUniqSupply us; (u2, u3) = splitUniqSupply u23
            (s', bs') = cloneRecIdBndrs s u1 (map fst prs)
        in Let (Rec [ (b', clone s' u r) | (b', (_, r), u) <- zip3 bs' prs (listSplitUniqSupply u2) ])
               (clone s' u3 x)
      Case x b t alts ->
        let (u1, u23) = splitUniqSupply us; (u2, u3) = splitUniqSupply u23
            (s', b')  = cloneIdBndr s u1 b
            alt (Alt c bs r) u = let (ua, ub) = splitUniqSupply u
                                     (s'', bs') = cloneBndrs s' ua bs
                                 in Alt c bs' (clone s'' ub r)
        in Case (clone s u2 x) b' (substTyUnchecked s t) (zipWith alt alts (listSplitUniqSupply u3))
      Cast x co   -> Cast (clone s us x) (substCo s co)
      Tick t x    -> Tick (substTickish s t) (clone s us x)
      Type t      -> Type (substTyUnchecked s t)
      Coercion co -> Coercion (substCo s co)
      WebLam {}   -> pprPanic "cloneLocals: WebLam" (ppr e)
      WebApp {}   -> pprPanic "cloneLocals: WebApp" (ppr e)

-- | One object from several (the chunk's and its stub's)
joinObjs :: HscEnv -> [FilePath] -> FilePath -> IO ()
joinObjs _ [o] out = copyFile o out
joinObjs hsc_env os out = joinObjectFiles hsc_env os out

-- | Every module's unused exports (Note [Unused exports] in
-- GHC.WebCore.Pipeline), by module name
readUnusedExportsAll :: DynFlags -> IO (Set.Set (String, String))
readUnusedExportsAll dflags = case websUnusedExports dflags of
  Nothing -> return Set.empty
  Just f  -> do { ok <- doesFileExist f
                ; txt <- if ok then readFile f else return ""
                ; return $! Set.fromList [ (m, o) | [m, o] <- map words (lines txt) ] }

-- | One program from the captured modules (in dependency order)
mergeGuts :: UniqSupply -> DynFlags -> Bool -> Set.Set (String, String) -> ModGuts -> [ModGuts] -> ModGuts
mergeGuts us dflags whole unused main_guts gutss
  = main_guts { mg_binds        = concat [ map (bind g) (mg_binds g) | g <- gutss ]
              , mg_exports      = exports
              , mg_tcs          = concatMap mg_tcs gutss
              , mg_insts        = if whole then [] else concatMap mg_insts gutss
              , mg_inst_env     = emptyInstEnv
              , mg_fam_insts    = fam_insts
              , mg_fam_inst_env = extendFamInstEnvList emptyFamInstEnv fam_insts
              , mg_patsyns      = concatMap mg_patsyns gutss
              , mg_rules        = concat [ map (rule g) (mg_rules g) | g <- gutss ]
              , mg_foreign      = foldr (plusStubs . mg_foreign) NoStubs gutss
              , mg_foreign_files = concatMap mg_foreign_files gutss
              , mg_anns         = concatMap mg_anns gutss
              , mg_complete_matches = concatMap mg_complete_matches gutss }
  where
    fam_insts = concatMap mg_fam_insts gutss
    main_mod  = mg_module main_guts

    -- What the merged program exports: decides which types' constructors
    -- outside modules see (classifyTyCon in GHC.WebCore.Pipeline)
    exports | whole     = mg_exports main_guts
            | otherwise = [ a | g <- gutss, a <- mg_exports g, keepAvail a ]
    keepAvail (Avail n) = not (cut_name n)
    keepAvail _         = True
    cut_name n = case nameModule_maybe n of
      Just m  -> (moduleNameString (moduleName m), getOccString n) `Set.member` unused
      Nothing -> False

    -- Every top-level binder as it will be: not exported unless a root,
    -- and, unless a root, with a fresh unique (Note [Merging the chunk's
    -- modules]).  Occurrences become these; the binders also get their
    -- unfoldings and rules rewritten, whose occurrences are these too (not
    -- the rewritten binders: no knot), and the simplifier's substitution
    -- makes every occurrence its binder.
    tops   = [ (mg_module g, b) | g <- gutss, b <- bindersOfBinds (mg_binds g) ]
    finals = zipWith final tops (uniqsFromSupply us)
    final (_, b) u
      | isLocalId b, not (root b) = localise (if isExportedId b then setIdNotExported b else b) `setVarUnique` u
      | otherwise                 = b
    -- a module's own binders, by unique; another module's, by module and unique
    own   = Map.fromListWith (++) [ (m, [(b, f)]) | ((m, b), f) <- zip tops finals ]
    owns  = Map.map mkVarEnv own
    cross = Map.fromList [ ((m, getKey (getUnique b)), f) | ((m, b), f) <- zip tops finals ]
    resolve g v
      | isGlobalId v, Just m <- nameModule_maybe (idName v)
      = Map.lookup (m, getKey (getUnique v)) cross
      | otherwise
      = Map.lookup (mg_module g) owns >>= \e -> lookupVarEnv e v

    -- Not in the whole program: a binder that is not a root loses its
    -- module (Note [Interfaces of a chunk]); Tidy gives the merged
    -- module the ones it exposes
    localise b | whole     = b
               | otherwise = setIdName b (localiseName (idName b))
    root b | whole     = entry b
           | otherwise = isExportedId b && not (cut_name (idName b))
    -- main, and GHC's :Main.main wrapper (in the module :Main)
    entry b = case nameModule_maybe (idName b) of
      Just m -> (m == main_mod && getOccString b == fromMaybe "main" (mainFunIs dflags))
                || take 1 (moduleNameString (moduleName m)) == ":"
      Nothing -> False

    info g b = b `setIdUnfolding` unf g (realIdUnfolding b)
                 `setIdSpecialisation` mkRuleInfo (map (rule g) (ruleInfoRules (idSpecialisation b)))
    unf g u = case u of
      CoreUnfolding { uf_tmpl = t } | isStableUnfolding u -> u { uf_tmpl = expr g t }
                                    | otherwise           -> noUnfolding
      DFunUnfolding { df_args = as } -> u { df_args = map (expr g) as }
      _                              -> u
    rule g r = case r of
      Rule { ru_args = as, ru_rhs = rhs } -> r { ru_args = map (expr g) as, ru_rhs = expr g rhs }
      BuiltinRule {}                      -> r

    top_bndr g b = info g (fromMaybe b (resolve g b))
    bind g (NonRec b e) = NonRec (top_bndr g b) (expr g e)
    bind g (Rec prs)    = Rec [ (top_bndr g b, expr g e) | (b, e) <- prs ]

    -- Occurrences of the top-level binders become the binders
    expr g = go
      where
        go = \case
          Var v | isId v, Just v' <- resolve g v -> Var v'
          Var v          -> Var v
          Lit l          -> Lit l
          App f a        -> App (go f) (go a)
          Lam b x        -> Lam (local b) (go x)
          Let bd x       -> Let (lbind bd) (go x)
          Case x b t as  -> Case (go x) b t [ Alt c bs (go r) | Alt c bs r <- as ]
          Cast x co      -> Cast (go x) co
          Tick t x       -> Tick t (go x)
          Type t         -> Type t
          Coercion co    -> Coercion co
          WebLam w b x   -> WebLam w (local b) (go x)
          WebApp w f a   -> WebApp w (go f) (go a)
        lbind (NonRec b e) = NonRec (local b) (go e)
        lbind (Rec prs)    = Rec [ (local b, go e) | (b, e) <- prs ]
        -- a local binder's stable unfolding may mention them too
        local b | isId b    = b `setIdUnfolding` unf g (realIdUnfolding b)
                | otherwise = b

    plusStubs NoStubs s = s
    plusStubs s NoStubs = s
    plusStubs (ForeignStubs h1 c1) (ForeignStubs h2 c2) = ForeignStubs (h1 `mappend` h2) (c1 `mappend` c2)
