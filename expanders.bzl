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
    via the root of an anchor file rather than as a constant string.
  * "$$" always escapes: "$$(location //foo)" expands to the literal
    "$(location //foo)" as it does in genrules. The native two-pass
    composition above instead expands the location reference and keeps the
    escaped "$".
  * Make variable values containing "$" are rejected with an error instead of
    being recursively expanded (Make ":=" semantics) as
    ctx.expand_make_variables would do.
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

def _var_value_token(name, value):
    # ctx.expand_make_variables recursively expands "$" references in make
    # variable values (Make ":=" semantics, up to depth 10, except when the
    # value is exactly the variable's name). expanders.bzl does not support
    # this and fails instead of silently emitting the unexpanded value.
    if "$" in value and value != name:
        fail(("the value of $(%s) is \"%s\", which contains \"$\": expanders.bzl does not " +
              "support the recursive expansion of make variable values performed by " +
              "ctx.expand_make_variables") % (name, value))
    return var_token(value)

def _resolve_var(ctx, extra_vars, state, name):
    # Extra variables take precedence over ctx.var, just like the
    # additional_substitutions parameter of ctx.expand_make_variables.
    if name in extra_vars:
        return _var_value_token(name, extra_vars[name])
    if name == "BINDIR" or (name == "GENDIR" and ctx.genfiles_dir.path == ctx.bin_dir.path):
        return root_token(_anchor_file(ctx, state))
    if name in ctx.var:
        return _var_value_token(name, ctx.var[name])
    fail("$(%s) not defined" % name)

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

def _expand(ctx, explicit, targets, extra_vars, state, args, input):
    if "$" not in input:
        # Fast path: the Args object retains only the attribute value itself.
        args.add(input)
        return

    tokens = []
    for kind, payload in parse(input):
        if kind == LIT:
            tokens.append(payload)
        elif kind == VAR:
            tokens.append(_resolve_var(ctx, extra_vars, state, payload))
        else:
            tokens.append(_resolve_location(ctx, explicit, targets, state, payload[0], payload[1]))

    emit(args, tokens)

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
        expand = lambda args, input: _expand(ctx, explicit, targets, extra_vars, state, args, input),
    )

expanders = struct(
    make = _expander_init,
)
