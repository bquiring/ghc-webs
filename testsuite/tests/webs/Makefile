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
