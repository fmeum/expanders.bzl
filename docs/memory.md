# Memory analysis: lazy Args-based expansion vs. eager native expansion

This document quantifies the retained-heap cost of `expanders.bzl` compared to
the eager native composition

```starlark
args.add(ctx.expand_make_variables("expand", ctx.expand_location(input, targets), extra_vars))
```

All source references are to Bazel 9.2.0. Object sizes assume the JVM Bazel
ships: Java 25 with `-XX:+UseCompactObjectHeaders` (baked into the embedded
JDK via `src/minimize_jdk.sh` and confirmed with `jcmd <server_pid>
VM.flags`), compressed oops, compact Latin-1 strings and 8-byte alignment —
i.e. 8-byte object headers, a 12-byte array base offset and 4-byte
references. Empirical numbers were measured with `jcmd <server_pid>
GC.class_histogram` against dedicated Bazel servers, using the benchmark in
`tests/benchmark/`.

## 1. Where command line memory lives

`ctx.actions.args()` is backed by `StarlarkCustomCommandLine.Builder`
(`c.g.d.build.lib.analysis.starlark.StarlarkCustomCommandLine`), which appends
to a single flat `ArrayList<Object>`. When the Args object is consumed by an
action, `Builder#build` calls `arguments.toArray()` and wraps the result in a
`StarlarkCustomCommandLine` holding one exact-sized `Object[]` (stored as an
array rather than an `ImmutableList` "to save memory", per the field comment).

That object is what survives analysis: `ctx.actions.write(content = <Args>)`
constructs a `ParameterFileWriteAction` whose `commandLine` field references
it (`ParameterFileWriteAction.java:62`); `ctx.actions.run` stores it inside
`CommandLines`. Actions live in the `RuleConfiguredTargetValue`, i.e. in the
Skyframe analysis cache, for the lifetime of the server (until invalidation or
`--discard_analysis_cache`). Every byte counted below is therefore paid **per
action, per configuration, for the whole server lifetime** — this is exactly
the memory the class javadoc means by "this is retained in Skyframe, so care
is taken to be as compact as possible".

The command line is expanded in three stages (see the class javadoc):
analysis stores only the "recipe"; right before execution the recipe is
preprocessed (nested sets flattened, `map_each` invoked — with path mapping
applied through the `StarlarkSemantics` so `File.path`/`File.root.path`
return mapped values); string formatting happens lazily during iteration.
Strings produced by `map_each` are therefore **transient**: they exist during
action key computation and action execution only.

### 1.1 The exact `Object[]` encoding

`args.add(value)` (`Args.java, addSingleArg`):

* appends **1 slot** (4 bytes) referencing the value — and, crucially, for
  strings first calls **`s.intern()`** (`Args.java:524`). See §4.
* with `format =`: a shared marker plus 2 slots (`SingleFormattedArg.push`).

`args.add_all(...)` / `args.add_joined(...)` (`VectorArg.push`):

| slot | condition | marginal cost |
|---|---|---|
| `VectorArg` marker | always | 4 B; the instance is **interned** (`strongInterner`/`weakInterner`, lines 155–156) and keyed by (feature bits, stringification type, semantics, global `map_each` function). All calls in this library share a handful of instances: **0 B** |
| `map_each` function | only if *not* a top-level function | 0 slots for `expanders.bzl` — a global `StarlarkFunction` is folded into the interned `VectorArg` ("saving a slot in arguments") |
| `Location` | if `map_each` present | 4 B slot; the Location instance is the `CallExpression`'s own `lparenLocation` field, reused for every execution of the call site (`CallExpression.java:24`, `Eval.java:713`): **no new object**. Measured: 40,000 calls, +0 retained Locations |
| count `Integer` | list with ≠ 1 element (`HAS_SINGLE_ARG` otherwise) | 4 B slot; boxed values ≤ 127 come from the `Integer` cache. Measured: +0 |
| values | list elements are copied inline | 4 B/slot; the Starlark list wrapper is *not* retained |
| `join_with` | `add_joined` | 4 B slot; the `""` literal is shared per loaded module |

So the per-call overhead of this library's emission strategies is:

* fast path `args.add(input)`: **4 B**
* `add_all([token], map_each = ...)`: 3 slots = **12 B**
* `add_joined(n tokens, join_with = "", ...)`: n + 4 slots = **4n + 16 B**

### 1.2 Starlark value sizes

| value | layout | retained bytes |
|---|---|---|
| fresh `String`, L Latin-1 chars | 24 B (8 B header + fields, padded) + `byte[]` (12 + L, padded to 8) | **≈ 36 + L, rounded up** |
| 1-tuple `(v,)` | `SingletonTuple` — one field, no array (`net.starlark.java.eval.SingletonTuple`) | **16 B** |
| 2-tuple | `RegularTuple` 16 B + `Object[2]` 24 B | **40 B** |
| 3-tuple | `RegularTuple` 16 B + `Object[3]` 24 B (12 B base + 12 B, padded) | **40 B** |
| `File`, depset, `ctx.var` value, tag literal | shared, retained elsewhere | **0 B** |
| Starlark `int` in [-128, 99,872) | `StarlarkInt.of` returns cached singletons (`smallints[100_000]`) | **0 B** |

Tuples are the optimal token container available to Starlark code. The
immutable list variants match them exactly (`ImmutableSingletonStarlarkList`
holds a single field like `SingletonTuple`; `RegularImmutableStarlarkList`
wraps just an `Object[]` like `RegularTuple`), but rule code cannot produce
them: list literals and `depset.to_list()` (which is
`StarlarkList.copyOf(thread.mutability(), ...)`, a fresh copy per call)
return `MutableStarlarkList`, which carries `size`, `iteratorCount` and
`mutability` fields on top of the array — 24 B plus potential capacity slack,
even once frozen.

`ctx.var` materializes one `Dict` per rule context on first access
(`StarlarkRuleContext.var()`), sized by the number of visible make variables
— a handful globally, a few dozen when a C++ toolchain contributes. That is
not a retention concern: `StarlarkRuleContext#close` nulls
`cachedMakeVariables` when the rule's analysis completes, so the dict is
analysis-phase garbage, and it is built at most once per rule, whereas eager
expansion constructs a fresh `ConfigurationMakeVariableContext` on every
`ctx.expand_make_variables` call. Its entries are copied by reference from
the suppliers' retained maps (`collectMakeVariables` → `putAll`), so the
value strings a token retains are shared with the configuration and
toolchain providers. (Suppliers may compute the occasional value on demand;
a token retaining such a value costs the same as eager expansion would, and
whole-string `$(VAR)` arguments are interned via `args.add` regardless.)

## 2. Retained cost per token (this library)

| token | encoding | marginal retained bytes |
|---|---|---|
| whole input without `$` | the attr string itself | 4 (slot) |
| composite argument | `(input, val0, ..., valk-1)` — the attribute string plus one value per site; sites are recovered by re-running `parse()` at render time | 4 + tuple (16 + 4·(1 + k), padded) + value costs; **no literal text and no offsets retained** |
| literal pieces of make variable *values* (retained per use) | fresh strings | ~36 + L |
| `$(VAR)` site in a composite | bare shared value string (value pieces containing `$$` are unescaped eagerly and thus fresh) | 4 |
| `$(BINDIR)` / `$(GENDIR)` | `(anchor_file, "b")` pair (kept: a make variable site cannot be re-resolved purely) | 4 + 40, plus one-time anchor (§5) |
| `$(execpath)`/`$(location)`/`$(rootpath)` site in a composite | bare `File` — the re-parse recovers the function | 4 |
| plural exec/rootpath site in a composite | bare files tuple | 4 + (28 + 4n, padded), shared across all tokens referencing the same target via the location map |
| `$(rlocationpath)`/`$(rlocationpaths)` site in a composite | bare `File`/files tuple when the workspace name is `_main` (the renderer substitutes a constant) or the files are all external (`../` runfiles paths never consult it); tagged triple only for main-repo files under a non-default workspace name | 4, or 4 + 40 in the rare tagged case |
| whole-argument `$(rootpath)` / plural (tagged, rendered without re-parsing) | pair around File/files tuple | 4 + 40 |

No token ever embeds an exec path: paths come from `File.path`,
`File.short_path`, `File.root.path` inside the `map_each` callback, which
returns strings that only live for the duration of fingerprinting or
execution. This is also precisely why path mapping works: with `map_each`,
mapped paths "are only created during iteration" (class javadoc).

CPU trade-off: the callback runs once during action key computation
(`VectorArg#addToFingerprint` → `applyMapEach`) and once during execution
preprocessing — twice per action lifecycle, on small token counts.

## 3. Retained and transient cost of the eager native composition

**`ctx.expand_location`** (`StarlarkRuleContext.expandLocation`, line 1030)
has *no fast path*: every call allocates a `StringBuilder` and returns a
fresh copy even for inputs containing no `$(` at all
(`LocationExpander.expand`, line 175). It also rebuilds the entire
label → files map for **every input string**
(`makeLabelMap(targets)` per call): O(#targets) `LinkedHashMap` +
`ImmutableMap` churn per string — transient, but it costs CPU and minor-GC
throughput during analysis. `expanders.make` builds the equivalent dict once
per rule.

**`ctx.expand_make_variables`** (line 951) short-circuits when the string
contains no `$` (`TemplateExpander.expand`), otherwise allocates a
`StringBuilder` plus a fresh `ConfigurationMakeVariableContext` per call.

**Retained**: the final string, via `args.add(...)` — subject to interning
(§4). For content unique to a target: **≈ 36 + L** where L is the fully
expanded length (paths included).

## 4. `Args.add` interns scalar strings — and what that means

`Args.addSingleArg` calls `s.intern()` on every string added as a scalar
(`Args.java:522–525`). Vector values (`add_all`/`add_joined`) are **not**
interned. Consequences, all verified empirically (§6):

* Eagerly expanded strings whose content repeats across targets/actions
  collapse to **one instance per build**. This makes eager expansion nearly
  free (amortized) for arguments whose expansion does not depend on the
  target: make-variable-only strings (`"$(TARGET_CPU)"` expands identically
  everywhere in a configuration) and shared tool paths
  (`"--tool=$(execpath //some:tool)"`).
* Eagerly expanded strings that embed target-specific output paths — the
  common case for `$(location)` on a rule's own inputs/outputs — are unique,
  and interning buys nothing: full ≈ 36 + L retained per action.
* Our fast path benefits symmetrically: `add(attr_string)` inserts the
  already-retained attribute instance into the JVM string table (no copy).
* Our literal substrings go through the vector path and are *not* interned,
  so identical `"--flag="` fragments across many targets are retained once
  per token; from Starlark we cannot call `intern()` (see §8.2).

## 5. One-time costs

* **Anchor file** (only if `$(BINDIR)`/`$(GENDIR)` is used): one
  `DerivedArtifact` (~32 B + `PathFragment` + its path string, ≈ 180 B all
  in), one `FileWriteAction` writing `""` (~100 B), plus action-registration
  bookkeeping — **roughly 300–400 B per rule instance**, amortized over every
  BINDIR reference in that rule. The eager BINDIR string
  (`bazel-out/<config>/bin`, ~34 chars) is interned and effectively costs one
  instance per configuration, so for pure memory the eager form wins here;
  the anchor exists to make `$(BINDIR)` respond to path mapping, which no
  eager string can.
* **Module pinning**: any Args using a global `map_each` function retains
  that `StarlarkFunction`, which transitively retains its module — globals,
  resolver metadata and function ASTs (`bazel dump
  --memory=deep,count:configured_target:<label>` attributes ~160 KB of
  `Identifier`/`Resolver$Binding`/`StarlarkFunction` objects reachable this
  way for the `expanders.bzl` load chain). This is the same module instance
  the `BzlLoadValue` already retains, so the *marginal* cost is zero; it only
  matters as attribution noise in per-node memory tooling, or if bzl-load
  values are evicted while actions live on.

## 6. Empirical validation

Setup: `tests/benchmark/` defines three rule variants with identical
attributes — `null_expand` (adds the raw attr strings), `lazy_expand` (this
library), `eager_expand` (native composition) — 400 targets each, 100
expansion strings per target (50 `"--tN.optJ=$(execpath :genK.txt)"`
composites, 25 single-token execpaths with a unique literal suffix, 25
20-file `$(execpaths :group)` plurals with a unique suffix), all literal
content made unique per target. Measurement: per variant, fresh server,
`bazel build --nobuild //benchmark:all_<variant>`, then
`jcmd $(bazel info server_pid) GC.class_histogram` (triggers a full GC).

Deltas vs. `null` for 40,000 args (Bazel 9.2.0, darwin_arm64):

| class | lazy Δ | eager Δ | lazy: model says |
|---|---|---|---|
| `byte[]` | +1,081,040 B (+40,337) | **+13,956,288 B** (+40,499) | 100 substrings/target × ~27 B = 1,080,000 B |
| `String` | +966,744 B (+40,277) | +971,304 B (+40,471) | 40,000 × 24 B = 960,000 B |
| `Object[]` | +1,083,608 B (+10,540) | +2,528 B (+96) | slots + tuple arrays ≈ 1,049,600 B |
| `RegularTuple` | +166,400 B (+10,400) | 0 | 26/target × 400 = **10,400 exactly** |
| `SingletonTuple`, `Location`, `Integer` | +0 | +0 | +0 (shared/cached) |
| **total live heap** | **+3,311,576 B** | **+15,322,408 B** | 3,256,000 B (−1.7 %) |

* **Lazy: ~83 B/arg. Eager: ~383 B/arg — 4.6× more.** The gap is entirely
  expanded-path content (`byte[]`); eager's average argument here is 334
  chars because of the plurals. For workloads dominated by plurals the ratio
  grows without bound; for single short paths it shrinks (see the shape table
  below).
* The model matches measurement to within 2 % overall, and exactly for tuple
  counts.
* Running the same benchmark with expansion strings *identical across
  targets* makes the eager variant indistinguishable from `null`
  (+341 strings) — that is `Args.add`'s `String.intern()` at work (§4), and
  is how that call was discovered.

Per-shape retained bytes per argument (model, L = path length ≈ 55,
k = number of actions across the build adding an argument with identical
content):

| input shape | eager | lazy |
|---|---|---|
| plain literal (no `$`) | (36 + L)/k | 4 |
| `"$(execpath :own_output)"` (unique content) | ≈ 96 | **4** (plain `args.add(file)`) |
| `"--flag=$(execpath :own_output)"` | ≈ 104 | ≈ 52 (composite: 3 slots + a 2-tuple, constant in literal length) |
| `"--tool=$(execpath //shared:tool)"` | ≈ 104/k → ~0 | ≈ 52 |
| `"$(TARGET_CPU)"`, `"a $(VAR) b"` | ≈ (36 + L)/k → ~0 | 28–170 |
| `"$(execpaths :group)"`, n = 20 | ≈ 1,160 | ≈ 56 (+ 112 shared once) |
| `"$(BINDIR)"` | ≈ 80/k → ~0 | 44 + anchor once |

The var-only and literal rows are why the emitter does not use the
token encoding across the board — see §7.

## 7. The cost model (implemented in `expanders.bzl`'s emitter)

1. **Emit eagerly when no token references a `File`.** For inputs consisting
   only of literals, escapes and make variables, the resolved token values
   are joined at analysis time and `args.add`ed: interning then deduplicates
   the result across all targets sharing the input and configuration,
   beating the token encoding by 1–2 orders of magnitude in the common case.
   Nothing is lost: such arguments contain nothing path-mappable, and the
   single-pass `$$`/error semantics stay in the parser. A special case falls
   out for free: a whole-string `$(VAR)` becomes `args.add(<shared value>)` —
   4 bytes, zero copies.
2. **Emit single dynamic values directly.** A whole-argument exec path is
   `args.add(file)` (1 slot; directories use a singleton
   `args.add_all(expand_directories = False)`, 2 slots, since `args.add`
   rejects them); any other single value is a singleton `add_all` with
   `map_each` (3 slots). Only files whose path contains no `/` (root-package
   source files, whose native rendering has a `./` prefix) skip the plain
   `add` form.
3. **Render everything else by re-parsing the input.** Composite arguments
   become a single tuple `(input, val0, ..., valk-1)`: the rendering
   callback re-runs the very same `parse()` on the input string (a pure
   function of it), takes literal segments from the scan (unescaping `$$`
   then) and substitutes the retained values for the sites in order. Neither
   literal text nor offsets are retained; a site that resolved to several
   values stores them as a nested tuple group. This subsumed two earlier
   strategies — `format =` strings (fresh string per action, `%%` escaping)
   and offset-carrying span tuples — at the cost of running the O(n) parse
   during fingerprinting and execution, alongside the `map_each` evaluation
   that already happens then. Trade-off unchanged from spans: for *computed*
   (non-attribute) inputs the token retains the full input including the
   macro text; for attribute strings that text is already retained by the
   package.

With `split = True`, static arguments split eagerly into interned chunks,
and dynamic arguments use a rendering callback that returns one string per
space-separated chunk of the expanded string — Args fans a returned list out
into multiple arguments — which is byte-identical to splitting the eagerly
expanded string, including plural expansions embedded in larger arguments.

Behavioral details of native expansion discovered during this analysis
(the implicit location map of `ctx.expand_location`, executable preference,
duplicate-target errors, recursive make variable values) are documented in
the [README](../README.md).

## 8. What Bazel could improve

Upstream changes that would lower retained memory further, roughly by
expected impact for location/make-variable expansion workloads:

1. **Native lazy location expansion in `Args`.** The endgame would be a new
   argument type in `StarlarkCustomCommandLine` storing (reference to the
   original attribute string, an `int[]` of span offsets, the resolved
   `File`s) and rendering at expansion time. Unlike this library, which must
   retain literal segments as fresh Starlark substrings (≈ 36 + L bytes
   each, §2), spans would retain 8 bytes per segment and *zero* new strings,
   and every rule would get path-mappable expansion without a library.
2. **Intern strings on the vector path.** `Args.add` interns scalar strings
   (`Args.java:524`) but `add_all`/`add_joined` values are stored as-is.
   Interning them (perhaps only short ones, to bound the CPU cost on large
   value lists) would make repeated dynamically produced fragments such as
   this library's `"--flag="` substrings free across targets — the last
   case where eager expansion can beat the lazy encodings on memory.
   Format strings, by contrast, are not worth interning upstream: they are
   typically `.bzl` literals and thus already shared per call site; only
   dynamically built ones (as in this library's format strategy) are fresh
   per rule instance.
3. **Trim the per-call `VectorArg` slots.** The `Location` stored for
   `map_each` error reporting is the call site's own
   `CallExpression#lparenLocation`, so it could join the interned
   `VectorArg` (which already holds the global `map_each` function) instead
   of occupying a slot in every call — one saved slot per
   `add_all`/`add_joined`. Similarly, `HAS_SINGLE_ARG` could be generalized
   to encode small element counts in feature bits, saving the boxed-count
   slot.
4. **Memoize the location map per rule.** `ctx.expand_location` rebuilds the
   full label→files map — including flattening `filesToBuild` nested sets of
   all `srcs`/`deps`/`tools` prerequisites — for *every call*
   (`StarlarkRuleContext.expandLocation` → `makeLabelMap`, plus the memoized
   supplier is per-`LocationExpander`, which is per-call). A per-rule-context
   cache would remove O(#targets × #strings) transient allocations during
   analysis. (This library builds its map once per expander.)
5. **Expose alias labels and label resolution to Starlark.** Not a retention
   win, but `Target.alias_label` (or `AliasProvider#getDependencyLabels`)
   and a repo-mapping-aware `ctx.resolve_label(...)` would remove this
   library's `str(target)` parsing and the native-assisted fallback for
   apparent repository names, which transiently materializes path→`File`
   maps.
6. **Store artifacts' paths root-relative.** Every derived artifact retains
   its full exec path (`bazel-out/<config>/bin/...`) as a flat string inside
   its `PathFragment`. Deriving the exec path lazily from a shared root
   reference plus the root-relative path would deduplicate the prefix across
   all artifacts of a configuration — far beyond expansion workloads, and
   correspondingly invasive.
7. **Field-based small-arity tuples.** Compact object headers (which Bazel's
   embedded JDK enables unconditionally) shift the economics of
   `SingletonTuple`-style specializations: a two-field `PairTuple` would be
   16 B — the same size as today's one-element `SingletonTuple` — versus
   40 B for `RegularTuple` plus its `Object[2]` (−60 %; pre-compact-headers
   the saving was 24 B → 40 B, −40 %). A three-field class lands at 24 B
   (vs. 40) and a four-field one also at 24 B (vs. 48). All tuple allocation
   already funnels through `Tuple.wrap`'s length switch, so the memory side
   is a small change; the open question is interpreter CPU: `Tuple.get`,
   `size` and iteration call sites go from bimorphic to megamorphic, which
   needs Starlark benchmarks. Two-element tuples dominate retained
   small-tuple populations (the `map_each` token pattern in §2 is nearly all
   pairs: 10,400 per 400 benchmark targets). Lists gain nothing analogous:
   everything Starlark rule code can produce is a `MutableStarlarkList`
   whose extra fields (`size`, `iteratorCount`, `mutability`) are demanded
   by list semantics, and freezing cannot change an object's class; the
   immutable list variants (where a singleton specialization already
   exists) are only constructed from Java.

## 9. Reproducing

```sh
cd tests
for kind in null lazy eager; do
  bazel shutdown
  bazel build --nobuild //benchmark:all_$kind
  jcmd $(bazel info server_pid) GC.class_histogram > /tmp/histo_$kind.txt
done
# per-configured-target attribution (counts shared reachable objects too):
bazel config   # pick the hash of the target configuration
bazel dump "--memory=deep,summary:configured_target://benchmark:lazy1@<hash>"
```

Caveats of `bazel dump --memory=deep`: it counts everything *reachable* from
the node (including objects shared with other nodes, such as the loaded .bzl
module graph via `map_each`, and the configuration), and it does not size
string contents — use JVM histograms for byte-accurate comparisons.
