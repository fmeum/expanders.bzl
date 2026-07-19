# Adopting expanders.bzl in existing rulesets

Concrete migration sketches for the high-value expansion sites found in a
survey of popular rulesets (July 2026), and the API additions that would make
adoption easier. Sites whose sinks are env dicts or runtime launcher scripts
are out of scope: those carry runfiles-relative paths with nothing to path
map and little to retain.

## 1. bazel-lib `run_binary` (and `expand_template`'s gating)

Today (`lib/private/run_binary.bzl`):

```starlark
can_path_map = True
targets = ctx.attr.tools + ctx.attr.srcs
if chdir:
    expanded_chdir = expand_variables(ctx, ctx.expand_location(chdir, targets = targets), ...)
    can_path_map = expanded_chdir == chdir
    args.add("--chdir", expanded_chdir)
for a in ctx.attr.args:
    if a == "$(BINDIR)":
        # special case kept lazy via map_each so it can path map
        args.add_all([expansion_outputs[0]], map_each = _bindir_path, expand_directories = False)
    else:
        expanded = expand_variables(ctx, ctx.expand_location(a, targets = targets), ...)
        can_path_map = can_path_map and expanded == a
        args.add_all(split_args(expanded))
```

With expanders.bzl:

```starlark
expander = expanders.make(
    ctx,
    targets = ctx.attr.tools + ctx.attr.srcs,
    extra_vars = expanders.genrule_vars(outs = expansion_outputs, inputs = inputs),
)
if chdir:
    args.add("--chdir")
    expander.expand(args, chdir)
for a in ctx.attr.args:
    expander.expand(args, a, split = True)
```

(Both `genrule_vars` and `split = True` are implemented; the
`supports-path-mapping` execution requirement can be gated on
`expander.supports_path_mapping()`, which stays `True` unless an unmappable
raw output path flows into an argument.)

* The `$(BINDIR)` special case, the `can_path_map` bookkeeping and the
  "disable `supports-path-mapping` if expansion changed anything" logic are
  all deleted: every expansion stays lazy and mapped.
* bazel-lib's genrule-style variables (`$@`, `$(<)`, `$(@D)`, `$(RULEDIR)`)
  become `extra_vars` that retain the output Files directly and render
  lazily — path mapped, which their current eager strings never are.
* `split_args` tokenizes the *expanded* string; `split = True` reproduces
  exactly that (the rendering callback splits the lazily expanded string and
  returns a list, which `Args` fans out into multiple arguments), so there
  is no semantic caveat beyond quoting: `split_args` respects shell quotes,
  the split here is plain spaces.

## 2. rules_rust `rustc_flags`

Today (`rust/private/utils.bzl`, `rust/private/rustc.bzl`): a helper rewrites
`"$(execpath " → "$${pwd}/$(execpath "` before expansion, manually re-splits
plural expansions to prefix every path with `$${pwd}/`, and the rule then
disables path mapping for the whole rustc action whenever any flag or env
value contained a location macro (`supports_path_mapping =
not target_has_location_expansion`).

With expanders.bzl:

```starlark
expander = expanders.make(ctx, targets = deduplicate(data))  # rules_rust already dedups
for flag in authored_rustc_flags:
    for directive in ("$(execpath ", "$(location "):
        flag = flag.replace(directive, "$${pwd}/" + directive)  # pre-expansion rewrite, unchanged
    expander.expand_split(rustc_flags, flag, format_each = None or "$${pwd}/%s")  # additions A1+A3
```

* Singular `$${pwd}/` prefixing already works unchanged: it is an edit of
  the *input* string before expansion.
* The plural re-split/prefix machinery is replaced by A1's per-file fan-out
  with A3's `format_each` applied to location-derived arguments.
* `has_location_expansion` and `supports_path_mapping = False` are deleted —
  the reason rustc actions lose path mapping today disappears.
* Residual friction: `map_each = map_flag` post-processing of expanded flag
  strings must move to pre-expansion inspection of the authored flags (the
  path-mapping gate already inspects authored flags, so precedent exists).
  `rustc_env` stays eager (env sink, out of scope).

## 3. bazel-skylib `run_binary` (baseline: pure drop-in)

```starlark
# before
args = [ctx.expand_location(a, targets = [ctx.attr.tool]) for a in ctx.attr.args]
ctx.actions.run(arguments = args, ...)
# after
args = ctx.actions.args()
expander = expanders.make(ctx, targets = [ctx.attr.tool])
for a in ctx.attr.args:
    expander.expand(args, a)
ctx.actions.run(arguments = [args], ...)
```

No semantic change at all (skylib does one argument per attr string and no
make variables). This is also the only surveyed site where the native lazy
expansion PR (`ctx.expand_location(lazy = True)`) is an equally pure drop-in.

## 4. rules_go `gc_goopts`/`x_defs` (provider-crossing)

Today: `_expand_opts` eagerly expands make variables in `new_go_info`, the
strings travel inside `GoInfo`/`GoArchive`, and a *different* action file
later shell-quotes and joins them into single `Args` values
(`compile_args.add("-gcflags", quote_opts(gc_flags))`).

With expanders.bzl this needs addition A2 (token-returning API):

```starlark
# at provider construction
expander = expanders.make(ctx)
go_info.gc_goopts = [expander.tokens(opt) for opt in attr.gc_goopts]
# at action construction (different file, possibly different rule)
expanders.emit_joined(compile_args, go_info.gc_goopts, join_with = " ")  # addition A2/A6
```

Tokens are plain Starlark values (Files, strings, small tuples), so they are
provider-safe, and the provider then retains tokens instead of expanded
strings. Caveat: `quote_opts` shell-quotes each opt before joining; lazy
quoting would need a quote mode on the joining API (A6) — without it, only
opts that never need quoting round-trip byte-identically. `x_defs` has the
same shape plus a `"%s=%s"` key prefix, which A2 handles since the prefix is
a literal token.

## 5. rules_swift `copts`/`linkopts` (in-repo API boundary)

Today: `swift_library` eagerly expands and passes `user_compile_flags:
list[str]` into `swift_common.compile`; linkopts end up retained in linking
contexts. The code even comments on the shape problem: "These can't use
additional_inputs since expand_locations needs targets, not files."

Migration = addition A2 threaded through the in-repo API: rules could pass
`[expander.tokens(opt) for opt in ctx.attr.copts]` and `compile()` emits them
into its `Args` via `expanders.emit`. Compile flags work fully; `linkopts`
only up to the `cc_common.link(user_link_flags = ...)` boundary, which is a
native API that accepts strings — out of reach without a Bazel-side change.

## 6. rules_kotlin compiler plugin options (provider-crossing)

Today: `kt_compiler_plugin` stores `id + "=" + ctx.expand_location(v, data)`
in a provider; the consuming compile action formats each entry again into
`plugin:%s:%s` via `map_each`. With A2: store `expander.tokens(id + "=" + v)`
(the prefix is input-string manipulation, fine before expansion) and emit
with a `format = "plugin:..%s"`-style wrapper at the consumer. Shape is
mechanical; the provider schema changes from strings to token lists.

## Proposed additions

* **A1 — implemented** as `expander.expand(args, input, split = True)`:
  static arguments split eagerly into interned chunks; dynamic arguments
  render lazily and split in the callback, fanning out into multiple
  arguments — byte-identical to `.split(" ")` of the eager expansion,
  embedded plurals included.
* **A2 — token API for deferred emission**: `expander.tokens(input) ->
  opaque` plus `expanders.emit(args, tokens)` (and `emit_split`). Tokens are
  provider-safe plain values, so expansion can happen where the attribute
  and its `targets` live while emission happens where the `Args` is built —
  the provider retains tokens, not expanded strings. Unblocks: rules_go,
  rules_swift, rules_kotlin, rules_rust toolchain flags.
* **A3 — `format_each` on split/fan-out emission**: applied per produced
  argument (`"$${pwd}/%s"`), covering rules_rust's per-path prefixing
  without post-expansion string surgery.
* **A4 — implemented** as `expanders.genrule_vars(outs = [], inputs = [])`:
  `extra_vars` builder for `$@`, `$(<)`, `$(@D)`, `$(RULEDIR)` matching
  genrule and bazel-lib's `expand_variables`; the values retain the Files
  directly and render lazily and path mapped. A `supports_path_mapping()` helper was also added for gating
  the execution requirement on actions whose expansions may contain
  unmappable raw output paths.

Non-goals: lazy shell quoting inside joined arguments (rules_go
`quote_opts`; would need a quoting mode and diverges from native semantics),
`rootpath`-flavored env expansion (env sinks are out of scope), and
tokenize-after-expand via `ctx.tokenize`/Bourne tokenization (rules_cc,
rules_apple), which is inherently eager.
