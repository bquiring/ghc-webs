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

# chunk002: a chunk of two modules inside a program; Main outside it
# (Note [Chunks] in GHC.WebCore.Chunk)
.PHONY: chunk002
chunk002:
	'$(TEST_HC)' $(TEST_HC_OPTS) --make -fcore-webs-chunk -fcore-webs-chunk-modules=chunk002.modules \
	  -fcore-webs-unused-exports=chunk002.unused -O -fcore-webs-early -fcore-webs-boundary -fcore-webs-useless \
	  -fcore-webs-defunc -fcore-webs-data-split -fcore-webs-data-unbox -dcore-lint \
	  -v0 chunk002.hs -outputdir chunk002.out -o chunk002
	./chunk002
