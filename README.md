# expanders.bzl

A memory-efficient, path-mapping-aware replacement for `ctx.expand_location`
and `ctx.expand_make_variables` that emits into a `ctx.actions.args()` object
instead of returning strings.

Native expansion returns eagerly built strings that embed exec paths. When
such strings are added to an action's command line, they are retained in
Bazel's analysis cache for the lifetime of the server, and they can never be
path mapped. This library instead parses the input once during analysis and
adds a compact, lazy "recipe" to the `Args` object: paths are only computed
when the action's command line is expanded, by which point Bazel applies path
mapping (`--experimental_output_paths=strip`) if the consuming action
supports it. For arguments containing expanded paths this retains about 4×
less memory than native expansion; see [docs/memory.md](docs/memory.md) for
the full cost model and measurements.

## Setup

The module is not yet published to the Bazel Central Registry. Use an
override in your `MODULE.bazel`:

```starlark
bazel_dep(name = "expanders.bzl")
git_override(
    module_name = "expanders.bzl",
    remote = "...",
    commit = "...",
)
```

The library requires Bazel 7 or newer (tested with 9.2.0).

## Usage

```starlark
load("@expanders.bzl", "expanders")

def _my_rule_impl(ctx):
    args = ctx.actions.args()
    expander = expanders.make(
        ctx,
        targets = ctx.attr.data,
        extra_vars = {"CUSTOM_VAR": "value"},
    )
    for opt in ctx.attr.opts:
        expander.expand(args, opt)
    ...
```

Each `expander.expand(args, input)` call behaves like

```starlark
args.add(ctx.expand_make_variables(
    "opts",
    ctx.expand_location(input, ctx.attr.data),
    {"CUSTOM_VAR": "value"},
))
```

but without materializing any expanded strings during analysis. Create at
most one expander per rule context (it can be used with any number of `Args`
objects): expanding `$(BINDIR)` or `$(GENDIR)` declares a helper file with a
fixed name.

Additional API:

* `expander.expand(args, input, split = True)` emits one argument per
  space-separated chunk of the expanded string, byte-identical to splitting
  the eagerly expanded string — including plural location expansions, which
  fan out into one argument per file (still lazily, via a rendering callback
  that returns a list of strings).
* `expanders.genrule_vars(outs = [], inputs = [])` returns an `extra_vars`
  dict providing `$@`, `$(@D)`, `$(RULEDIR)` and `$(<)` with genrule
  semantics. The values retain the given Files directly and render lazily,
  so they are path mapped. `extra_vars` generally accepts File values in
  addition to strings: a File-valued variable expands to the file's raw
  exec path, rendered lazily.
* `expander.supports_path_mapping()` reports whether everything expanded so
  far is compatible with path mapping; it turns `False` when a raw
  output-directory-like path that cannot be lazily mapped survives into an
  argument (e.g. a make variable value pointing into another configuration's
  output directory). Use it to gate the `supports-path-mapping` execution
  requirement of the consuming action.

### Path mapping

Because paths are computed lazily, they automatically respect path mapping.
Build with `--experimental_output_paths=strip` and declare support on the
consuming action, e.g.:

```starlark
ctx.actions.run(
    ...,
    execution_requirements = {"supports-path-mapping": "1"},
)
```

This also works for `ctx.actions.write(content = <Args>)` (Bazel 9+), which
is what the test suite uses to compare mapped and unmapped outputs.

## Semantics

The library reproduces the native expansion semantics of
`ctx.expand_make_variables` applied to the result of `ctx.expand_location`
(this composition order is the only one that works natively:
`ctx.expand_make_variables` fails on `$(location ...)` expressions, while
`ctx.expand_location` leaves make variables alone). This includes some
behaviors that are easy to miss:

* **Make variables**: `$(VAR)` and single-character references such as `$@`
  are looked up in `extra_vars` first (mirroring `additional_substitutions`),
  then `ctx.var`. `$$` escapes to `$`. Values are recursively expanded (Make
  `:=` semantics, up to a depth of 10, except when a value is exactly the
  variable's own name), with the same errors as native expansion on cycles,
  overly deep chains and location functions inside values. Values embedding
  the output directory path — such as toolchain-provided variables pointing
  at generated tools — additionally become subject to path mapping.
* **Location functions**: `location`/`locations` (synonyms of
  `execpath`/`execpaths`), `rootpath(s)` and `rlocationpath(s)`. Singular
  functions fail if the target expands to more than one file. Paths that do
  not contain a `/` get a `./` prefix (native "callable" paths), and plural
  expansions are space-joined after sorting.
* **Implicit targets**: exactly like `ctx.expand_location`
  (`LocationExpander#buildLocationMap`), labels are resolved against more
  than the explicit `targets` list: the rule's predeclared outputs, the
  prerequisites of an attribute literally named `srcs` (expanding to their
  files), and the prerequisites of attributes named `deps`,
  `implementation_deps` or `tools` (expanding to their executable, if any,
  and their files otherwise) are always addressable. An attribute named
  `data` is — perhaps surprisingly — *not* consulted. Files contributed for
  the same label are merged into a set.
* **Aliases**: a target depended on via an alias must be referenced by the
  alias's label in the explicit `targets` list; for the implicitly collected
  attributes, both the alias and the actual target's label work
  (`AliasProvider#getDependencyLabels`). This library recovers alias labels
  by parsing `str(target)`, since they are not otherwise exposed to Starlark.
* **Executable preference**: with
  `--incompatible_locations_prefers_executable` (default `true`), a target
  that provides an executable and whose default outputs are not exactly one
  file expands to just the executable; prerequisites of `deps`/`tools`
  attributes expand to their executable unconditionally.
* **Errors**: unknown variables, unknown location functions, unterminated
  references, labels that are not declared prerequisites, empty or
  multi-file expansions for singular functions, and duplicate labels in
  `targets` all fail with the same messages as native expansion.

## Known divergences from native expansion

* `$$` always escapes: `$$(location //foo)` expands to the literal
  `$(location //foo)`, exactly as in genrules. The native two-pass
  composition instead expands the location reference (and then typically
  fails on the leftover `$`).
* `--incompatible_locations_prefers_executable=false` is not supported: the
  library always applies the default behavior. Observing the actual flag
  value would require every rule using the library to declare an implicit
  attribute (`config_setting` + `select`).
* Labels with an apparent repository name (`@repo//...`) are resolved by
  delegating to native `ctx.expand_location` for just that expression and
  mapping the resulting paths back to `File` objects (all strings involved
  are garbage collected after analysis). For *plural* location functions
  this mapping splits on spaces, so files with spaces in their paths are not
  supported in that specific combination.

## Testing

The test suite lives in the `tests` module (pinned to Bazel 9.2.0, which the
mapped tests need for `execution_requirements` on `ctx.actions.write`):

```sh
cd tests && bazel test //...
```

`expander_test` compares the library's output byte-for-byte against native
expansion — both without path mapping (outputs must be identical) and with
path mapping enabled (outputs must be identical after mapping the
configuration segment of the output directory). `expander_failure_test`
asserts error-message parity, and `expander_golden_test` pins down the
intentional divergences. `tests/benchmark/` contains the retained-memory
benchmark described in [docs/memory.md](docs/memory.md).
