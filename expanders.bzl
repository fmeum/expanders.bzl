"""Lazy, Args-based replacements for ctx.expand_location and ctx.expand_make_variables.

Example:

    load("@expanders.bzl", "expanders")

    def _my_rule_impl(ctx):
        args = ctx.actions.args()
        expander = expanders.make(ctx, targets = ctx.attr.data)
        for input in ctx.attr.opts:
            expander.expand(args, input)
        ...

expander.expand(args, input) behaves like

    args.add(ctx.expand_make_variables(
        "opts",
        ctx.expand_location(input, ctx.attr.data),
        extra_vars,
    ))

with the following differences:

  * No expanded strings are retained by the Args object: it only references
    (substrings of) the original attribute value, File objects and make
    variable values that are already retained elsewhere. In particular, no
    string containing an exec path is ever created during analysis. Paths are
    computed by a map_each callback when the command line is expanded.
  * Because paths are computed late, they are automatically subject to path
    mapping (--experimental_output_paths=strip) if the consuming action
    supports it. This includes $(BINDIR) and $(GENDIR), which are expanded
    via the root of an anchor file rather than as a constant string, as well
    as any make variable whose value embeds the output directory path (such
    as toolchain-provided variables pointing at generated tools).
  * "$$" always escapes: "$$(location //foo)" expands to the literal
    "$(location //foo)" as it does in genrules. The native two-pass
    composition above instead expands the location reference and keeps the
    escaped "$".
  * --incompatible_locations_prefers_executable is assumed to be true (its
    default): a target providing an executable expands to the executable if
    its default outputs are not exactly one file. Observing the actual flag
    value would require every rule using this library to declare an implicit
    attribute (config_setting + select), which is not worth it; setting the
    flag to false is thus not supported.

Labels in location expressions are resolved exactly like ctx.expand_location
resolves them (see LocationExpander#buildLocationMap): in addition to the
explicit targets, the rule's predeclared outputs as well as the prerequisites
of any of its attributes named "srcs", "deps", "implementation_deps" or
"tools" (but, perhaps surprisingly, not "data") can be referenced. Targets
that were depended on via an alias can be referenced by the label of the
alias and, for the implicitly collected attributes only, also by the label of
the actual target. Passing the same label twice in targets is an error.
"""

load(":cost_model.bzl", "emit")
load(":ops.bzl", "callable_path", "location_token", "root_token", "var_token")
load(":parse.bzl", "LIT", "LOC", "VAR", "parse")

_SINGULAR_LOCATION_FUNCTIONS = {
    "execpath": None,
    "location": None,
    "rlocationpath": None,
    "rootpath": None,
}

# Attributes whose prerequisites ctx.expand_location makes addressable in
# location expressions in addition to the explicitly passed targets, expanding
# to their executable if they have one and to their files otherwise.
_IMPLICIT_FILES_TO_RUN_ATTRS = ("deps", "implementation_deps", "tools")

def _fn_name(fn):
    # Native error messages always refer to $(location)/$(locations), no
    # matter which location function was actually used.
    return "locations" if fn.endswith("s") else "location"

def _format_label(label):
    s = str(label)

    # Match the way native error messages render labels in the main repository.
    return s[2:] if s.startswith("@@//") else s

def _alias_label(target):
    """Returns the label of the alias a target was depended on via, if any.

    That label is not exposed to Starlark directly, but can be recovered from
    the target's string representation, which looks like
    "<alias target //pkg:name of //pkg:actual>".
    """
    s = str(target)
    if not s.startswith("<alias target "):
        return None
    alias = s[len("<alias target "):s.index(" of ")]

    # repr() omits the canonical repository prefix for the main repository.
    return Label(alias if alias.startswith("@") else "@@" + alias)

def _dependency_label(target):
    """Returns the label by which a target is referenced in the targets list.

    For a target that is (a chain of) alias(es), target.label refers to the
    actual target, but native location expansion only matches the label of
    the alias itself for explicitly provided targets
    (AliasProvider#getDependencyLabel).
    """
    alias = _alias_label(target)
    return alias if alias != None else target.label

def _dependency_labels(target):
    """Returns all labels by which an implicitly collected target is referenced.

    Mirrors AliasProvider#getDependencyLabels: the label of the first alias
    and the label of the actual target (intermediate aliases of a chain are
    not included).
    """
    alias = _alias_label(target)
    if alias != None and alias != target.label:
        return (alias, target.label)
    return (target.label,)

def _executable(target):
    if DefaultInfo not in target:
        return None
    files_to_run = target[DefaultInfo].files_to_run
    return files_to_run.executable if files_to_run != None else None

def _expansion_files(target):
    """Returns the files an explicitly provided target expands to.

    Mimics --incompatible_locations_prefers_executable=true (the default,
    which this library assumes unconditionally): a target that provides an
    executable and whose default outputs are not a single file expands to
    just the executable.
    """
    files = target.files.to_list()
    if len(files) != 1:
        executable = _executable(target)
        if executable != None:
            return [executable]
    return files

def _map_add(location_map, label, files):
    # Values are dicts used as ordered sets: the same label can be
    # contributed to by both the explicit targets and the implicitly
    # collected attributes, potentially with different files.
    file_set = location_map.get(label)
    if file_set == None:
        file_set = {}
        location_map[label] = file_set
    for file in files:
        file_set[file] = None

def _output_label(ctx, file):
    # Predeclared outputs always live in the rule's own package.
    short_path = file.short_path
    if short_path.startswith("../"):
        short_path = short_path.split("/", 2)[2]
    package = ctx.label.package
    name = short_path[len(package) + 1:] if package else short_path
    return ctx.label.same_package_label(name)

def _collect_outputs(ctx, location_map):
    for attr_name in dir(ctx.outputs):
        # The default executable of an executable rule is not an output file
        # target and thus not addressable in location expressions.
        if attr_name == "executable":
            continue
        value = getattr(ctx.outputs, attr_name)
        for file in value if type(value) == "list" else [value]:
            if type(file) == "File":
                _map_add(location_map, _output_label(ctx, file), [file])

def _collect_targets(ctx, attr_name, location_map, files_fn):
    targets = getattr(ctx.attr, attr_name, None)
    if type(targets) != "list":
        return
    for target in targets:
        if type(target) != "Target":
            return
        files = files_fn(target)
        for label in _dependency_labels(target):
            _map_add(location_map, label, files)

def _srcs_files(target):
    return target.files.to_list()

def _files_to_run_files(target):
    # Unlike for explicitly provided targets, the executable is preferred
    # even if the target's default outputs are a single file.
    executable = _executable(target)
    return [executable] if executable != None else target.files.to_list()

def _location_map(ctx, explicit, state):
    """Lazily builds the full label-to-files map of ctx.expand_location.

    Mirrors LocationExpander#buildLocationMap with allowDataAttributeEntries
    set to false and collectSrcs set to true: the map contains the rule's
    predeclared outputs, the prerequisites of its "srcs" attribute (expanding
    to their files), the prerequisites of its "deps", "implementation_deps"
    and "tools" attributes (expanding to their executable, if any, and their
    files otherwise) and the explicitly provided targets, with files for the
    same label merged into a set.

    The map only lives during the analysis phase; Args objects retain the
    per-label files tuples, which reference Files that are retained by the
    rule's attributes anyway.
    """
    location_map = state.get("location_map")
    if location_map == None:
        mutable_map = {}
        _collect_outputs(ctx, mutable_map)
        _collect_targets(ctx, "srcs", mutable_map, _srcs_files)
        for attr_name in _IMPLICIT_FILES_TO_RUN_ATTRS:
            _collect_targets(ctx, attr_name, mutable_map, _files_to_run_files)
        for label, files in explicit.items():
            _map_add(mutable_map, label, files)
        location_map = {label: tuple(file_set.keys()) for label, file_set in mutable_map.items()}
        state["location_map"] = location_map
    return location_map

def _anchor_file(ctx, state):
    # An empty file declared only so that its lazily evaluated (and thus path
    # mapping aware) root.path can stand in for $(BINDIR).
    anchor = state.get("anchor")
    if anchor == None:
        anchor = ctx.actions.declare_file(ctx.label.name + ".expanders.bzl.anchor")
        ctx.actions.write(anchor, "")
        state["anchor"] = anchor
    return anchor

def _split_on_output_dir(ctx, state, piece):
    """Splits a literal piece on occurrences of the output bin directory path.

    Make variable values provided by toolchains can embed paths under the
    output directory (e.g. paths to generated tools). Replacing each
    occurrence with the lazily evaluated root path of the anchor file keeps
    such values byte-identical while making them subject to path mapping.

    Any output-directory-like path that remains afterwards (e.g. a tool path
    under another configuration's output directory) cannot be mapped and is
    recorded in state for supports_path_mapping().
    """
    bin_dir = ctx.bin_dir.path
    if bin_dir not in piece:
        if "bazel-out/" in piece or "blaze-out/" in piece:
            state["unmappable"] = True
        return [piece]
    tokens = []
    for i, part in enumerate(piece.split(bin_dir)):
        if i > 0:
            tokens.append(root_token(_anchor_file(ctx, state)))
        if part and ("bazel-out/" in part or "blaze-out/" in part):
            state["unmappable"] = True
        if part:
            tokens.append(part)
    return tokens

def _resolve_var(ctx, extra_vars, state, name):
    """Returns the expansion tokens for a make variable reference.

    Mirrors TemplateExpander: make variable values are recursively expanded
    (Make ":=" semantics), except when a value is exactly the name of its
    variable. The recursion depth check applies to every recursively reached
    value, even one without any "$", just like in native expansion.

    Starlark forbids recursive functions, so the recursion over nested
    values is driven by an explicit stack of (depth, payload) items: a
    positive depth marks a variable reference in a value expanded at that
    depth, -1 a literal piece of a value and -2 a location function in a
    value, which native expansion does not support. Items are pushed in
    reverse so that they are processed (and errors are reported) in the
    left-to-right order of native expansion.
    """
    tokens = []
    stack = [(1, name)]
    for _ in range(1 << 30):
        if not stack:
            return tokens
        depth, payload = stack.pop()
        if depth == -1:
            tokens.extend(_split_on_output_dir(ctx, state, payload))
            continue
        if depth == -2:
            fail("$(%s) not defined" % payload)

        # Extra variables take precedence over ctx.var, just like the
        # additional_substitutions parameter of ctx.expand_make_variables.
        if payload in extra_vars:
            value = extra_vars[payload]
        elif payload == "BINDIR" or (payload == "GENDIR" and ctx.genfiles_dir.path == ctx.bin_dir.path):
            tokens.append(root_token(_anchor_file(ctx, state)))
            continue
        elif payload in ctx.var:
            value = ctx.var[payload]
        else:
            fail("$(%s) not defined" % payload)

        if value == payload:
            # Native expansion appends such values verbatim, without
            # recursing (and thus without unescaping "$$").
            tokens.append(var_token(value))
            continue
        if depth > 10:
            fail("potentially unbounded recursion during expansion of '%s'" % value)
        if "$" not in value:
            tokens.extend(_split_on_output_dir(ctx, state, value))
            continue
        items = []
        for kind, start, end, payload in parse(value):
            if kind == LIT:
                items.append((-1, value[start:end]))
            elif kind == VAR:
                items.append((depth + 1, payload))
            else:
                items.append((-2, payload[0]))
        stack.extend(reversed(items))
    fail("unreachable")

def _resolve_label(ctx, fn, label_string):
    """Resolves a label string like native location expansion does.

    Returns None for labels with an apparent repository name: resolving those
    requires the repo mapping of the rule's repository, which is not exposed
    to Starlark (both Label() and the deprecated Label.relative() use the
    repo mapping of the .bzl file containing the call, which would be this
    file's).
    """
    if not label_string:
        fail("invalid label in $(%s) expression: invalid target name '': empty target name" % _fn_name(fn))
    if label_string.startswith("@@"):
        # Canonical labels are resolved independently of any repo mapping.
        return Label(label_string)
    if label_string.startswith("@"):
        return None
    if label_string.startswith("//"):
        return Label("@@" + ctx.label.repo_name + label_string)
    return ctx.label.same_package_label(label_string.removeprefix(":"))

def _lazy_path_map(location_map, state, key, to_path):
    # Maps the given kind of path to the corresponding File, for use by
    # _resolve_via_native. Only built on demand and never retained beyond the
    # analysis phase.
    path_map = state.get(key)
    if path_map == None:
        path_map = {}
        for files in location_map.values():
            for f in files:
                path_map[to_path(f)] = f
        state[key] = path_map
    return path_map

def _resolve_via_native(ctx, location_map, targets, state, fn, label_string):
    """Resolves a location expression with native ctx.expand_location.

    Used for labels with apparent repository names. The natively expanded
    paths are mapped back to File objects, so all strings created here are
    garbage collected when analysis completes; the Args object never retains
    them. Native label resolution and error reporting apply faithfully.
    """
    expanded = ctx.expand_location("$(%s %s)" % (fn, label_string), targets)
    if fn == "rootpath" or fn == "rootpaths":
        path_map = _lazy_path_map(location_map, state, "rootpath_map", lambda f: f.short_path)
    elif fn == "rlocationpath" or fn == "rlocationpaths":
        ws = ctx.workspace_name
        path_map = _lazy_path_map(
            location_map,
            state,
            "rlocationpath_map",
            lambda f: f.short_path[3:] if f.short_path.startswith("../") else ws + "/" + f.short_path,
        )
    else:
        path_map = _lazy_path_map(location_map, state, "execpath_map", lambda f: f.path)
    if fn in _SINGULAR_LOCATION_FUNCTIONS:
        # The whole expansion is a single path, even if it contains spaces.
        paths = [expanded]
    else:
        paths = expanded.split(" ") if expanded else []
    files = []
    for path in paths:
        f = path_map.get(path)
        if f == None:
            fail("label '%s' in $(%s) expression expands to a path containing spaces, which is not supported: %s" %
                 (label_string, fn, expanded))
        files.append(f)
    return tuple(files)

def _resolve_location(ctx, explicit, targets, state, fn, label_string):
    location_map = _location_map(ctx, explicit, state)
    label = _resolve_label(ctx, fn, label_string)
    if label == None:
        files = _resolve_via_native(ctx, location_map, targets, state, fn, label_string)
        return location_token(fn, files, ctx.workspace_name)
    files = location_map.get(label)
    if files == None:
        fail("label '%s' in $(%s) expression is not a declared prerequisite of this rule" %
             (_format_label(label), _fn_name(fn)))
    if not files:
        fail("label '%s' in $(%s) expression expands to no files" %
             (_format_label(label), _fn_name(fn)))
    if fn in _SINGULAR_LOCATION_FUNCTIONS and len(files) > 1:
        fail("label '%s' in $(location) expression expands to more than one file, please use $(locations %s) instead.  Files (at most 5 shown) are: [%s]" %
             (_format_label(label), _format_label(label), ", ".join(sorted([callable_path(f.path) for f in files])[:5])))
    return location_token(fn, files, ctx.workspace_name)

def _expand(ctx, explicit, targets, extra_vars, state, args, input, split):
    if "bazel-out/" in input or "blaze-out/" in input:
        # A literal output-directory-like path cannot be path mapped.
        state["unmappable"] = True
    if "$" not in input:
        if not split:
            # Fast path: the Args object retains only the attribute value
            # itself.
            args.add(input)
            return
        for chunk in input.split(" "):
            if chunk:
                args.add(chunk)
        return

    items = []
    for kind, start, end, payload in parse(input):
        if kind == LIT:
            items.append(("lit", start, end))
        elif kind == VAR:
            items.append(("site", start, end, _resolve_var(ctx, extra_vars, state, payload)))
        else:
            items.append((
                "site",
                start,
                end,
                [_resolve_location(ctx, explicit, targets, state, payload[0], payload[1])],
            ))

    emit(args, input, items, split)

def _expander_init(ctx, targets = [], extra_vars = {}):
    """Creates an expander for the given rule context.

    Args:
        ctx: The rule context.
        targets: A list of Targets whose labels can be referenced in location
            expressions, matching the targets parameter of
            ctx.expand_location. Just like there, the rule's predeclared
            outputs and the prerequisites of its "srcs", "deps",
            "implementation_deps" and "tools" attributes can always be
            referenced.
        extra_vars: A dict of additional make variables, matching the
            additional_substitutions parameter of ctx.expand_make_variables.

    Returns:
        A struct with an expand(args, input) method that expands make
        variables and location expressions in input and adds the result to
        the Args object args as a single argument.

    Create at most one expander per rule context (it can be used with any
    number of Args objects): expanding $(BINDIR) or $(GENDIR) declares a
    helper file with a fixed name.
    """
    explicit = {}
    for target in targets:
        label = _dependency_label(target)
        if label in explicit:
            fail("Label \"%s\" is found more than once in 'targets' list." % _format_label(label))
        explicit[label] = _expansion_files(target)
    state = {}
    return struct(
        expand = lambda args, input, split = False: _expand(ctx, explicit, targets, extra_vars, state, args, input, split),
        supports_path_mapping = lambda: not state.get("unmappable", False),
    )

def _genrule_vars(ctx, outs = [], inputs = []):
    """Returns extra_vars with genrule-style make variables.

    Provides $@ / $(@) (only with exactly one out), $(<) (only with exactly
    one input), $(@D) and $(RULEDIR), following genrule's semantics (and
    bazel-lib's expand_variables). The values embed the output directory
    path and thus become subject to path mapping via the output directory
    splitting performed on make variable values.

    Referencing $@ with multiple outs or $(<) with multiple inputs fails
    with "$(@) not defined" / "$(<) not defined", since the variables are
    only defined when unambiguous.

    Args:
        ctx: The rule context.
        outs: The list of output Files backing $@ and $(@D).
        inputs: The list of input Files backing $(<).

    Returns:
        A dict to pass (possibly after overlaying additional variables) as
        the extra_vars parameter of expanders.make.
    """
    parts = [ctx.bin_dir.path]
    if ctx.label.workspace_root:
        parts.append(ctx.label.workspace_root)
    if ctx.label.package:
        parts.append(ctx.label.package)
    rule_dir = "/".join(parts)
    vars = {"RULEDIR": rule_dir}
    if len(outs) == 1:
        vars["@"] = outs[0].path
        vars["@D"] = outs[0].path if outs[0].is_directory else outs[0].dirname
    else:
        vars["@D"] = rule_dir
    if len(inputs) == 1:
        vars["<"] = inputs[0].path
    return vars

expanders = struct(
    make = _expander_init,
    genrule_vars = _genrule_vars,
)
