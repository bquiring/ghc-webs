TOP=../..
include $(TOP)/mk/boilerplate.mk
include $(TOP)/mk/test.mk

# unused001: the listed export is no longer exported, and is deleted
# (Note [Unused exports] in GHC.WebCore.Pipeline)
.PHONY: unused001
unused001:
	'$(TEST_HC)' $(TEST_HC_OPTS) -O -fcore-webs-early -fcore-webs-boundary -fcore-webs-useless -dcore-lint \
	  -fcore-webs-unused-exports=unused001.txt -v0 unused001.hs -o unused001
	./unused001
	'$(TEST_HC)' --show-iface Unused001L.hi | sed -n '/^exports:/,/^defaults:/p'

# chunk001: the program compiled as one chunk (Note [Chunks] in
# GHC.WebCore.Chunk); only main stays exported
.PHONY: chunk001
chunk001:
	'$(TEST_HC)' $(TEST_HC_OPTS) --make -fcore-webs-chunk -O -fcore-webs-early -fcore-webs-boundary -fcore-webs-useless -fcore-webs-defunc -dcore-lint \
	  -v0 chunk001.hs -outputdir chunk001.out -o chunk001
	./chunk001

# chunk006: a chunk splitting newtypes of one module in another: their
# copies come from two TyCons with different type variables (Note [Copies of
# one newtype from two TyCons] in GHC.WebCore.DataSplit)
.PHONY: chunk006
chunk006:
	'$(TEST_HC)' $(TEST_HC_OPTS) --make -fcore-webs-chunk -O -fcore-webs-early -fcore-webs-data-split -dcore-lint \
	  -v0 chunk006.hs -outputdir chunk006.out -o chunk006
	./chunk006

# chunk008: two chunks of one program built one after the other, as hadrian
# builds a package's chunks: Chunk008B's unfolding mentions a binder that the
# first chunk's merge moved to Chunk008A, which Chunk008C (the second chunk)
# does not import; the second chunk reads its interface from the file
# (Note [Home modules outside a chunk] in GHC.Iface.Load)
.PHONY: chunk008
chunk008:
	'$(TEST_HC)' $(TEST_HC_OPTS) --make -no-link -O -fcore-webs-chunk -fcore-webs-chunk-modules=chunk008a.modules \
	  -dcore-lint -v0 Chunk008A.hs Chunk008B.hs -outputdir chunk008.out
	'$(TEST_HC)' $(TEST_HC_OPTS) --make -no-link -O -fcore-webs-chunk -fcore-webs-chunk-modules=chunk008c.modules \
	  -dcore-lint -v0 Chunk008C.hs -outputdir chunk008.out
	'$(TEST_HC)' $(TEST_HC_OPTS) -O -c chunk008.hs -outputdir chunk008.out -i./chunk008.out -v0
	'$(TEST_HC)' $(TEST_HC_OPTS) chunk008.out/Main.o chunk008.out/Chunk008A.o chunk008.out/Chunk008B.o \
	  chunk008.out/Chunk008C.o -o chunk008 -v0
	./chunk008

# chunk009: the second chunk's session, with other optimisation flags, must
# not compile the first chunk's modules again: Chunk009D re-exports f, which
# the first chunk cut from Chunk009E (Note [Modules below a chunk] in
# GHC.WebCore.Chunk)
.PHONY: chunk009
chunk009:
	'$(TEST_HC)' $(TEST_HC_OPTS) --make -no-link -O -fcore-webs-chunk -fcore-webs-chunk-modules=chunk009a.modules \
	  -fcore-webs-unused-exports=chunk009.unused -dcore-lint -v0 Chunk009D.hs Chunk009E.hs -outputdir chunk009.out
	'$(TEST_HC)' $(TEST_HC_OPTS) --make -no-link -O -fno-full-laziness -fcore-webs-chunk \
	  -fcore-webs-chunk-modules=chunk009c.modules -fcore-webs-unused-exports=chunk009.unused \
	  -dcore-lint -v0 Chunk009C.hs -outputdir chunk009.out
	'$(TEST_HC)' $(TEST_HC_OPTS) -O -c chunk009.hs -outputdir chunk009.out -i./chunk009.out -v0
	'$(TEST_HC)' $(TEST_HC_OPTS) chunk009.out/Main.o chunk009.out/Chunk009C.o chunk009.out/Chunk009D.o \
	  chunk009.out/Chunk009E.o -o chunk009 -v0
	./chunk009

# chunk010: Chunk010X, below the chunk {Chunk010C}, SOURCE-imports Chunk010M,
# which is not built yet: the chunk's session compiles only Chunk010C, not
# Chunk010M (Note [Modules below a chunk] in GHC.WebCore.Chunk)
.PHONY: chunk010
chunk010:
	'$(TEST_HC)' $(TEST_HC_OPTS) -O -c Chunk010M.hs-boot -outputdir chunk010.out -v0
	'$(TEST_HC)' $(TEST_HC_OPTS) -O -c Chunk010X.hs -outputdir chunk010.out -i./chunk010.out -v0
	'$(TEST_HC)' $(TEST_HC_OPTS) --make -no-link -O -fcore-webs-chunk -fcore-webs-chunk-modules=chunk010.modules \
	  -dcore-lint -v1 Chunk010C.hs -outputdir chunk010.out 2>&1 | grep Compiling | awk '{ print $$5 }'
	'$(TEST_HC)' $(TEST_HC_OPTS) -O -c Chunk010M.hs -outputdir chunk010.out -i./chunk010.out -v0
	'$(TEST_HC)' $(TEST_HC_OPTS) -O -c chunk010.hs -outputdir chunk010.out -i./chunk010.out -v0
	'$(TEST_HC)' $(TEST_HC_OPTS) chunk010.out/Main.o chunk010.out/Chunk010C.o chunk010.out/Chunk010X.o \
	  chunk010.out/Chunk010M.o -o chunk010 -v0
	./chunk010

# chunk012: a chunk of GHC.Utils.Monad.Codensity (copied) and instances derived
# via it, exports cut; every occurrence carries its binder's merged IdInfo
# (Note [Occurrences carry the binders' IdInfo] in GHC.WebCore.Chunk)
.PHONY: chunk012
chunk012:
	'$(TEST_HC)' $(TEST_HC_OPTS) --make -no-link -O -XGHC2021 -XMonoLocalBinds -fcore-webs-chunk \
	  -fcore-webs-chunk-modules=chunk012.modules -fcore-webs-unused-exports=chunk012.unused \
	  -dcore-lint -v0 Chunk012A.hs Chunk012B.hs -outputdir chunk012.out
	'$(TEST_HC)' $(TEST_HC_OPTS) -O -c chunk012.hs -outputdir chunk012.out -i./chunk012.out -v0
	'$(TEST_HC)' $(TEST_HC_OPTS) chunk012.out/Main.o chunk012.out/Chunk012A.o chunk012.out/Chunk012B.o \
	  -o chunk012 -v0
	./chunk012

# libcasejoin001: liberate case through a join point (Note [Liberate case
# through join points] in GHC.Core.Opt.LiberateCase): the loops in the final
# Core, one per constructor of the defunctionalised predicate (Note [One copy
# per alternative])
.PHONY: libcasejoin001
libcasejoin001:
	'$(TEST_HC)' $(TEST_HC_OPTS) -O2 -XBangPatterns -fcore-webs-early -fcore-webs-defunc \
	  -fliberate-case-join-points -dcore-lint -ddump-simpl -dsuppress-all -ddump-to-file \
	  -outputdir libcasejoin001.out -v0 libcasejoin001.hs -o libcasejoin001
	grep -c joinrec libcasejoin001.out/libcasejoin001.dump-simpl
	./libcasejoin001

# raisecall001: nofib integrate; both webs raised (Note [Raising through tail
# calls] in GHC.WebCore.Transform.ResultRaise, Note [Evaluated arguments] in
# GHC.WebCore.Transform.ArityRaise)
RAISECALL_OPTS = -O2 -fcore-webs-early -fcore-webs-arity-raise -fcore-webs-result-raise \
	-fcore-webs-boundary -fcore-webs-raise-through-calls -fcore-webs-evald-args -dcore-lint -dcore-webs-lint
.PHONY: raisecall001
raisecall001:
	'$(TEST_HC)' $(TEST_HC_OPTS) $(RAISECALL_OPTS) -ddump-webs-result-raise -ddump-webs-arity-raise \
	  -ddump-to-file -outputdir raisecall001.out -v0 raisecall001.hs -o raisecall001
	grep -h "^raised" raisecall001.out/*.dump-webs-*-raise | sed 's/_[A-Za-z0-9]*//g' | sort
	./raisecall001

# raisecall002: moving a constructor evaluates nothing new (undefined lazy fields)
.PHONY: raisecall002
raisecall002:
	'$(TEST_HC)' $(TEST_HC_OPTS) $(RAISECALL_OPTS) -ddump-webs-result-raise -ddump-webs-arity-raise \
	  -ddump-to-file -outputdir raisecall002.out -v0 raisecall002.hs -o raisecall002
	grep -h "^raised" raisecall002.out/*.dump-webs-*-raise | sed 's/_[A-Za-z0-9]*//g' | sort
	./raisecall002

# evaldarg001: the allocation raising an evaluated argument can cost: a lambda
# that keeps the box rebuilds it (Note [Evaluated arguments]); without arity
# raising against with it
.PHONY: evaldarg001
evaldarg001:
	'$(TEST_HC)' $(TEST_HC_OPTS) -O2 -rtsopts -fcore-webs-early -dcore-lint \
	  -outputdir evaldarg001.a -v0 evaldarg001.hs -o evaldarg001a
	'$(TEST_HC)' $(TEST_HC_OPTS) -O2 -rtsopts -fcore-webs-early -fcore-webs-arity-raise -fcore-webs-evald-args \
	  -dcore-lint -outputdir evaldarg001.b -v0 evaldarg001.hs -o evaldarg001b
	./evaldarg001a +RTS -tevaldarg001a.t --machine-readable -RTS
	./evaldarg001b +RTS -tevaldarg001b.t --machine-readable -RTS > /dev/null
	a=$$(grep "bytes allocated" evaldarg001a.t | grep -o "[0-9]*"); b=$$(grep "bytes allocated" evaldarg001b.t | grep -o "[0-9]*"); \
	  if [ $$b -gt $$a ]; then echo "raised: more allocation"; elif [ $$b -lt $$a ]; then echo "raised: less allocation"; else echo "raised: same allocation"; fi

# splitclass001: a class of the program's own, its dictionary not
# specialised away, split in a chunk (Note [Splitting classes] in
# GHC.WebCore.DataSplit); useless elimination and arity raising then change
# its methods
.PHONY: splitclass001
splitclass001:
	'$(TEST_HC)' $(TEST_HC_OPTS) --make -fcore-webs-chunk -O -fno-specialise -fcore-webs-early \
	  -fcore-webs-data-split -fcore-webs-split-classes -fcore-webs-useless -fcore-webs-arity-raise \
	  -dcore-lint -dcore-webs-lint -ddump-webs-data -ddump-to-file \
	  -v0 splitclass001.hs -outputdir splitclass001.out -o splitclass001
	grep -h "dictionaries of SplitClass001A.Shape" splitclass001.out/non-module.dump-webs-data | sed 's/ as .*//'
	./splitclass001

# chunk007: a chunk built twice into one output directory: the second
# capture's Tidy keeps its uniques although the first build's interfaces put
# the names in the name cache (allocateGlobalBinderWith in GHC.Iface.Env;
# hledger's generated lenses)
.PHONY: chunk007
chunk007:
	'$(TEST_HC)' $(TEST_HC_OPTS) --make -fcore-webs-chunk -O -dcore-lint -v0 chunk007.hs -outputdir chunk007.out -o chunk007
	./chunk007
	'$(TEST_HC)' $(TEST_HC_OPTS) --make -fcore-webs-chunk -O -dcore-lint -v0 chunk007.hs -outputdir chunk007.out -o chunk007
	./chunk007

# chunk002: a chunk of two modules inside a program; Main outside it
# (Note [Chunks] in GHC.WebCore.Chunk)
.PHONY: chunk002
chunk002:
	'$(TEST_HC)' $(TEST_HC_OPTS) --make -fcore-webs-chunk -fcore-webs-chunk-modules=chunk002.modules \
	  -fcore-webs-unused-exports=chunk002.unused -O -fcore-webs-early -fcore-webs-boundary -fcore-webs-useless \
	  -fcore-webs-defunc -fcore-webs-data-split -fcore-webs-data-unbox -dcore-lint \
	  -v0 chunk002.hs -outputdir chunk002.out -o chunk002
	./chunk002

# chunk003: a library built as a chunk, then used as Cabal would use it
# (Note [Chunks] in GHC.WebCore.Chunk)
.PHONY: chunk003
chunk003:
	cd chunk003lib && '$(TEST_HC)' $(TEST_HC_OPTS) --make -no-link -fcore-webs-chunk -O -fcore-webs-early \
	  -fcore-webs-boundary -fcore-webs-useless -fcore-webs-defunc -fcore-webs-data-split -fcore-webs-data-unbox \
	  -dcore-lint -v0 Chunk003A Chunk003B -outputdir out
	'$(TEST_HC)' $(TEST_HC_OPTS) -c -O -v0 -ichunk003lib/out chunk003.hs -o chunk003.o
	'$(TEST_HC)' $(TEST_HC_OPTS) -v0 chunk003.o chunk003lib/out/Chunk003A.o chunk003lib/out/Chunk003B.o -o chunk003
	./chunk003

# chunk004: a library chunk's SPECIALISE rule fires in an importer (Note
# [Interfaces of a chunk] in GHC.WebCore.Chunk)
.PHONY: chunk004
chunk004:
	cd chunk004lib && '$(TEST_HC)' $(TEST_HC_OPTS) --make -no-link -fcore-webs-chunk -O -fcore-webs-early \
	  -fcore-webs-boundary -fcore-webs-useless -fcore-webs-defunc -fcore-webs-data-split -fcore-webs-data-unbox \
	  -dcore-lint -v0 Chunk004A Chunk004B -outputdir out
	'$(TEST_HC)' $(TEST_HC_OPTS) -c -O -v0 -ichunk004lib/out -ddump-rule-firings chunk004.hs -o chunk004.o | grep -o 'Rule fired: USPEC total @Int'
	'$(TEST_HC)' $(TEST_HC_OPTS) -v0 chunk004.o chunk004lib/out/Chunk004A.o chunk004lib/out/Chunk004B.o -o chunk004
	./chunk004

# chunk005: a chunk with a module that has an hs-boot file (Note [Chunks]
# in GHC.WebCore.Chunk)
.PHONY: chunk005
chunk005:
	cd chunk005lib && '$(TEST_HC)' $(TEST_HC_OPTS) --make -no-link -fcore-webs-chunk -fcore-webs-chunk-modules=chunk.modules \
	  -O -fcore-webs-early -fcore-webs-boundary -fcore-webs-useless -fcore-webs-defunc -dcore-lint -v0 Chunk005A Chunk005B -outputdir out
	'$(TEST_HC)' $(TEST_HC_OPTS) -c -O -v0 -ichunk005lib/out chunk005.hs -o chunk005.o
	'$(TEST_HC)' $(TEST_HC_OPTS) -v0 chunk005.o chunk005lib/out/Chunk005A.o chunk005lib/out/Chunk005B.o -o chunk005
	./chunk005

# constspec001, constspec002: constant specialisation (Note [Constant
# specialisation] in GHC.WebCore.Transform.ConstSpec), keys from web classes
# and from calls; the copies made, per function
CONSTSPEC_OPTS = -O2 -fcore-webs-early -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise \
  -fcore-webs-result-raise -fcore-webs-strictness -dcore-lint -ddump-webs-spec -ddump-to-file
.PHONY: constspec001
constspec001:
	'$(TEST_HC)' $(TEST_HC_OPTS) $(CONSTSPEC_OPTS) -fcore-webs-spec-webs -outputdir constspec001.w -v0 constspec001.hs -o constspec001w
	'$(TEST_HC)' $(TEST_HC_OPTS) $(CONSTSPEC_OPTS) -fcore-webs-spec-calls -outputdir constspec001.c -v0 constspec001.hs -o constspec001c
	for d in w c; do echo $$d; grep -ho "^ *[A-Za-z]*_cs[0-9]*" constspec001.$$d/*.dump-webs-spec | sed 's/ //g' | sort; done
	./constspec001w
	./constspec001c

.PHONY: constspec002
constspec002:
	'$(TEST_HC)' $(TEST_HC_OPTS) $(CONSTSPEC_OPTS) -fcore-webs-spec-webs -outputdir constspec002.w -v0 constspec002.hs -o constspec002w
	'$(TEST_HC)' $(TEST_HC_OPTS) $(CONSTSPEC_OPTS) -fcore-webs-spec-calls -outputdir constspec002.c -v0 constspec002.hs -o constspec002c
	for d in w c; do echo $$d; grep -ho "^ *[A-Za-z]*_cs[0-9]*" constspec002.$$d/*.dump-webs-spec | sed 's/ //g' | sort; done
	./constspec002w
	./constspec002c
