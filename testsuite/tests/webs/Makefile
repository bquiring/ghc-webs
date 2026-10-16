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
