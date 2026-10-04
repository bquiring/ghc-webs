
gather benchmarks, build testing script
- try no-fib, look for existing testing harnesses

We're going to implement this paper in GHC
Webs and Flow-Directed Well-Typedness Preserving Program Transformations
https://dl.acm.org/doi/10.1145/3729280
familiarize yourself with this document.

Our initial changes to GHC will consist of four new passes:
- Initial Annotation
- Modified Linting and Type Checking
- Renaming
- Erasure
We want to inject this pipeline in GHC's main core pipeline, after Core optimizations are run.


Initial Annotation
==================
The way to do this is to modify GHC Core to add a new form for
- web-annotated functions (GHC/Core.hs)
- web-annotated calls (GHC/Core.hs)
- web-annotated arrows (GHC/Core/TyCo/Rep.hs)
while retaining the old function, call, and arrow forms.

Then we will build a source-to-source Core transform that turns existing
- function definitions into web-annotated functions
- same for calls and arrow types
This adds a new unique web to all of these locations
This program analysis needs to be modified from the original paper.
In particular, we need to handle coercions:
when adding new webs, we need to add them to coercions too.

Modified Linting and Type Checking
=================
Then we will modify the linter:
- we type check the IR, and whenever two webs are required to be the same, we will collect that pair
If two webs are already the same, the pair is not collected.
If a web function type is checked against a non-web function type, we error
These pairs form a graph.
After collecting all pairs, we will find a representative web for each
connected component by doing union-find over the pairs.

Renaming
==============
Then, we will traverse over the program term again and rewrite each web to its representative.

To check our work, we will rerun the linter after this phase and check that the collection of pairs is empty.


Erasure
==============
Eliminate all web-annotated forms in the entire program term by mapping back to the original forms.
This representation should be suitable for the rest of the compiler to consume.