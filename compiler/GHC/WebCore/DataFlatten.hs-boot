module GHC.WebCore.DataFlatten where

import GHC.Prelude
import GHC.Core ( CoreProgram )
import GHC.Core.TyCon ( TyCon )
import GHC.Types.Unique.Supply ( UniqSupply )
import GHC.Unit.Module ( Module )
import GHC.Utils.Outputable ( SDoc )

flattenFields :: Module -> UniqSupply -> [TyCon] -> CoreProgram -> (CoreProgram, [TyCon], SDoc)
