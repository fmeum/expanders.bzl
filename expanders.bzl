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

  * The Args object retains no expanded strings, only references to the
    original attribute value, Files and make variable values. Paths are
    computed by a map_each callback when the command line is expanded and
    are therefore subject to path mapping
    (--experimental_output_paths=strip), including $(BINDIR), $(GENDIR) and
    make variable values that embed the output directory path.
  * "$$" always escapes: "$$(location //foo)" expands to the literal
    "$(location //foo)" as in genrules, whereas the two-pass composition
    above expands the location reference.
  * --incompatible_locations_prefers_executable is assumed to be true (its
    default); setting it to false is not supported.

Labels in location expressions resolve like in ctx.expand_location
(LocationExpander#buildLocationMap): besides the explicit targets, the
rule's predeclared outputs and the prerequisites of its attributes named
"srcs", "deps", "implementation_deps" and "tools" (but not "data") are
addressable. A target depended on via an alias is referenced by the alias's
label and, for the implicitly collected attributes only, also by the actual
target's label. Passing the same label twice in targets is an error.
"""

load(":parse.bzl", "LIT", "VAR", "parse")
load(
    ":render.bzl",
    "MAIN_WORKSPACE",
    "callable_path",
    "expand_token",
    "expand_token_split",
    "render_execpaths",
    "render_parent_dir",
    "render_rlocationpath",
    "render_rlocationpaths",
    "render_root_path",
    "render_rootpath",
    "render_rootpaths",
)

_SINGULAR_LOCATION_FUNCTIONS = {
    "execpath": None,
    "location": None,
    "rlocationpath": None,
    "rootpath": None,
}

# Attributes whose prerequisites ctx.expand_location makes addressable in
# addition to the explicit targets, expanding to their executable if they
# have one and to their files otherwise.
_IMPLICIT_FILES_TO_RUN_ATTRS = ("deps", "implementation_deps", "tools")

def _fn_name(fn):
    # Native error messages always refer to $(location)/$(locations),
    # regardless of the location function actually used.
    return "locations" if fn.endswith("s") else "location"

def _format_label(label):
    # Native error messages render main repository labels without "@@".
    s = str(label)
    return s[2:] if s.startswith("@@//") else s

def _alias_label(target):
    """Returns the label of the alias a target was depended on via, if any.

    The label is not exposed to Starlark, but can be recovered from the
    target's string representation:
    "<alias target //pkg:name of //pkg:actual>".
    """
    s = str(target)
    if not s.startswith("<alias target "):
        return None
    alias = s[len("<alias target "):s.index(" of ")]

    # repr() omits the canonical repository prefix for the main repository.
    return Label(alias if alias.startswith("@") else "@@" + alias)

def _dependency_label(target):
    """Returns the label matched for an explicitly provided target.

    Mirrors AliasProvider#getDependencyLabel: the label of the alias the
    target was depended on via, not target.label (which is the actual
    target's label).
    """
    alias = _alias_label(target)
    return alias if alias != None else target.label

def _dependency_labels(target):
    """Returns the labels matched for an implicitly collected target.

    Mirrors AliasProvider#getDependencyLabels: the first alias and the
    actual target's label, omitting intermediate aliases of a chain.
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

    Mirrors makeLabelMap under --incompatible_locations_prefers_executable:
    a target with an executable expands to it unless its default outputs are
    a single file.
    """
    files = target.files.to_list()
    if len(files) != 1:
        executable = _executable(target)
        if executable != None:
            return [executable]
    return files

def _map_add(location_map, label, files):
    # Values are dicts used as sets: explicit targets and implicitly
    # collected attributes can contribute different files for one label.
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
        # target and thus not addressable.
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
    # even if the default outputs are a single file.
    executable = _executable(target)
    return [executable] if executable != None else target.files.to_list()

def _location_map(ctx, explicit, state):
    """Lazily builds the label-to-files map of ctx.expand_location.

    Mirrors LocationExpander#buildLocationMap with allowDataAttributeEntries
    = false and collectSrcs = true: predeclared outputs, "srcs"
    prerequisites (their files), "deps"/"implementation_deps"/"tools"
    prerequisites (their executable or files) and the explicit targets,
    merged per label.
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
    # An empty file declared only so that its lazily evaluated root.path and
    # dirname can stand in for $(BINDIR) and $(RULEDIR).
    anchor = state.get("anchor")
    if anchor == None:
        anchor = ctx.actions.declare_file(ctx.label.name + ".expanders.bzl.anchor")
        ctx.actions.write(anchor, "")
        state["anchor"] = anchor
    return anchor

def _split_on_output_dir(ctx, state, piece):
    """Splits a value piece on occurrences of the output directory path.

    Each occurrence is replaced by the anchor file's lazily evaluated root
    path, making values that embed the output directory subject to path
    mapping. Output-directory-like paths that remain (e.g. under another
    configuration's output directory) are recorded as unmappable.
    """
    bin_dir = ctx.bin_dir.path
    if bin_dir not in piece:
        if "bazel-out/" in piece or "blaze-out/" in piece:
            state["unmappable"] = True
        return [piece]
    tokens = []
    for i, part in enumerate(piece.split(bin_dir)):
        if i > 0:
            tokens.append((_anchor_file(ctx, state), "root"))
        if part and ("bazel-out/" in part or "blaze-out/" in part):
            state["unmappable"] = True
        if part:
            tokens.append(part)
    return tokens

def _resolve_var(ctx, extra_vars, state, name):
    """Returns the expansion tokens for a make variable reference.

    Mirrors TemplateExpander: values are recursively expanded (Make ":="
    semantics) except when a value is exactly its variable's name, and the
    depth limit of 10 applies to every recursively reached value, even one
    without a "$".

    Starlark forbids recursive functions, so the recursion runs on an
    explicit stack of (depth, payload) items: a positive depth is a variable
    reference in a value expanded at that depth, -1 a literal value piece
    and -2 a location function in a value (not supported by native
    expansion). Items are pushed in reverse so that processing and errors
    follow native left-to-right order.
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

        # Extra variables take precedence over ctx.var, like the
        # additional_substitutions parameter of ctx.expand_make_variables.
        if payload in extra_vars:
            value = extra_vars[payload]
            value_type = type(value)
            if value_type != "string":
                # Files are retained as-is, including source files: their
                # path strings are already interned structurally via the
                # artifact and would only pollute the global string
                # interning table if expanded eagerly through args.add.
                if value_type == "File":
                    tokens.append(value)
                elif value == _RULEDIR:
                    tokens.append((_anchor_file(ctx, state), "dirname"))
                elif value_type == "tuple" and len(value) == 2 and type(value[0]) == "File" and value[1] == "dirname":
                    tokens.append(value)
                else:
                    fail("the value of extra_vars[\"%s\"] must be a string or a File" % payload)
                continue
        elif payload == "BINDIR" or (payload == "GENDIR" and ctx.genfiles_dir.path == ctx.bin_dir.path):
            tokens.append((_anchor_file(ctx, state), "root"))
            continue
        elif payload in ctx.var:
            value = ctx.var[payload]
        else:
            fail("$(%s) not defined" % payload)

        if value == payload:
            # Appended verbatim without recursing or unescaping "$$", like
            # in native expansion.
            tokens.append(value)
            continue
        if depth > 10:
            fail("potentially unbounded recursion during expansion of '%s'" % value)
        if "$" not in value:
            tokens.extend(_split_on_output_dir(ctx, state, value))
            continue
        items = []
        for kind, start, end, piece_payload in parse(value):
            if kind == LIT:
                # "$$" is unescaped eagerly: value strings render verbatim,
                # and unescaping again would corrupt literal "$$".
                piece = value[start:end]
                items.append((-1, piece.replace("$$", "$") if "$$" in piece else piece))
            elif kind == VAR:
                items.append((depth + 1, piece_payload))
            else:
                items.append((-2, piece_payload[0]))
        stack.extend(reversed(items))
    fail("unreachable")

def _resolve_label(ctx, fn, label_string):
    """Resolves a label string like native location expansion does.

    Returns None for labels with an apparent repository name: those require
    the repo mapping of the rule's repository, which is not exposed to
    Starlark (Label() and Label.relative() use the repo mapping of the .bzl
    file containing the call, i.e. this file's).
    """
    if not label_string:
        fail("invalid label in $(%s) expression: invalid target name '': empty target name" % _fn_name(fn))
    if label_string.startswith("@@"):
        # Canonical labels resolve independently of any repo mapping.
        return Label(label_string)
    if label_string.startswith("@"):
        return None
    if label_string.startswith("//"):
        return Label("@@" + ctx.label.repo_name + label_string)
    return ctx.label.same_package_label(label_string.removeprefix(":"))

def _lazy_path_map(location_map, state, key, to_path):
    path_map = state.get(key)
    if path_map == None:
        path_map = {}
        for files in location_map.values():
            for f in files:
                path_map[to_path(f)] = f
        state[key] = path_map
    return path_map

def _resolve_via_native(ctx, location_map, targets, state, fn, label_string):
    """Resolves a location expression via native ctx.expand_location.

    Used for labels with apparent repository names: the natively expanded
    paths are mapped back to Files, so native label resolution and error
    reporting apply and all strings created here are garbage collected when
    analysis completes.
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

def _location_token(fn, files, workspace_name):
    # A plural expansion of a single file renders like the singular form
    # (sorting and joining are no-ops), so exec path singletons use the
    # cheaper bare-File encoding.
    if fn == "location" or fn == "execpath" or ((fn == "locations" or fn == "execpaths") and len(files) == 1):
        return files[0]
    elif fn == "rootpath":
        return (files[0], "rootpath")
    elif fn == "rlocationpath":
        return (files[0], "rlocationpath", workspace_name)
    elif fn == "locations" or fn == "execpaths":
        return (files, "execpaths")
    elif fn == "rootpaths":
        return (files, "rootpath")
    else:
        return (files, "rlocationpath", workspace_name)

def _resolve_location(ctx, explicit, targets, state, fn, label_string):
    location_map = _location_map(ctx, explicit, state)
    label = _resolve_label(ctx, fn, label_string)
    if label == None:
        files = _resolve_via_native(ctx, location_map, targets, state, fn, label_string)
        return _location_token(fn, files, ctx.workspace_name)
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
    return _location_token(fn, files, ctx.workspace_name)

def _add_single(args, val):
    """Emits a single whole-argument value with the cheapest encoding."""
    if type(val) == "File":
        if val.is_directory:
            # args.add rejects directories; a singleton add_all with
            # expand_directories = False stringifies them identically.
            args.add_all([val], expand_directories = False)
            return
        if "/" in val.path:
            # Default File stringification is the raw exec path, which
            # matches location expansion except for paths without a "/",
            # which get a "./" prefix there.
            args.add(val)
            return
        args.add_all([val], map_each = expand_token, expand_directories = False)
        return
    head = val[0]
    tag = val[1]
    if tag == "root":
        map_each = render_root_path
    elif tag == "dirname":
        map_each = render_parent_dir
    elif tag == "rootpath":
        map_each = render_rootpath if type(head) == "File" else render_rootpaths
    elif tag == "execpaths":
        map_each = render_execpaths
    else:
        stripped = _strip(val)
        if stripped == val:
            # An rlocation that needs its workspace name keeps the tagged
            # form.
            args.add_all([val], map_each = expand_token, expand_directories = False)
            return
        head = stripped
        map_each = render_rlocationpath if type(head) == "File" else render_rlocationpaths
    args.add_all([head], map_each = map_each, expand_directories = False)

def _all_external(files):
    for f in files:
        if not f.short_path.startswith("../"):
            return False
    return True

def _strip(val):
    """Drops token parts that composite rendering recovers from the re-parse.

    Location values lose their mode tags. rlocation values also lose the
    workspace name when rendering never consults it: for the Bzlmod default
    (the renderer substitutes MAIN_WORKSPACE) and for external files (their
    runfiles paths start with "../"). Singleton plurals strip all the way to
    a File so that bare files tuples always have at least two elements and
    stay distinguishable from the tagged forms. Anchor and dirname pairs are
    kept: their site is a make variable reference, which cannot be
    re-resolved purely.
    """
    if type(val) != "tuple":
        return val
    if len(val) == 2 and val[1] == "rootpath":
        return val[0]
    if len(val) == 2 and val[1] == "execpaths":
        return val[0]
    if len(val) == 3 and val[1] == "rlocationpath":
        head = val[0]
        if type(head) == "File":
            if val[2] == MAIN_WORKSPACE or head.short_path.startswith("../"):
                return head
            return val
        if val[2] == MAIN_WORKSPACE or _all_external(head):
            return head if len(head) > 1 else head[0]
    return val

def _expand(ctx, explicit, targets, extra_vars, state, args, input, split):
    """Expands input and adds the result to args.

    Emission strategies, from cheapest to most general (see docs/memory.md):
    static content expands eagerly into interned strings, a single value
    spanning the whole argument is emitted directly, and everything else
    becomes one composite token rendered by re-parsing the input.
    """
    if "bazel-out/" in input or "blaze-out/" in input:
        # A literal output-directory-like path cannot be path mapped.
        state["unmappable"] = True
    if "$" not in input:
        if not split:
            args.add(input)
            return
        for chunk in input.split(" "):
            if chunk:
                args.add(chunk)
        return

    parsed = parse(input)
    site_vals = []
    static = True
    for kind, _, _, payload in parsed:
        if kind == LIT:
            continue
        if kind == VAR:
            vals = _resolve_var(ctx, extra_vars, state, payload)
        else:
            vals = [_resolve_location(ctx, explicit, targets, state, payload[0], payload[1])]
        for val in vals:
            if type(val) != "string":
                static = False
        site_vals.append(vals)

    if static:
        pieces = []
        next_site = 0
        for kind, start, end, _ in parsed:
            if kind == LIT:
                lit = input[start:end]
                pieces.append(lit.replace("$$", "$") if "$" in lit else lit)
            else:
                pieces.extend(site_vals[next_site])
                next_site += 1

        # A single piece is added directly to reuse the existing string
        # instance; args.add interns the result either way.
        text = pieces[0] if len(pieces) == 1 else "".join(pieces)
        if not split:
            args.add(text)
        else:
            for chunk in text.split(" "):
                if chunk:
                    args.add(chunk)
    elif not split and len(parsed) == 1 and len(site_vals[0]) == 1:
        val = site_vals[0][0]
        if parsed[0][0] == VAR and type(val) == "File" and "/" not in val.path:
            # File-valued variables render as the raw exec path, which is
            # exactly default File stringification; _add_single would render
            # a path without a "/" with location expansion's "./" prefix.
            args.add(val)
        else:
            _add_single(args, val)
    else:
        vals = [_strip(sv[0]) if len(sv) == 1 else tuple(["group"] + sv) for sv in site_vals]
        args.add_all(
            [tuple([input] + vals)],
            map_each = expand_token_split if split else expand_token,
            expand_directories = False,
        )

def _expander_init(ctx, targets = [], extra_vars = {}):
    """Creates an expander for the given rule context.

    Create at most one expander per rule context (it can be used with any
    number of Args objects): expanding $(BINDIR), $(GENDIR) or $(RULEDIR)
    declares a helper file with a fixed name.

    Args:
        ctx: The rule context.
        targets: A list of Targets whose labels can be referenced in
            location expressions, matching the targets parameter of
            ctx.expand_location.
        extra_vars: A dict of additional make variables, matching the
            additional_substitutions parameter of ctx.expand_make_variables.
            Values may also be Files, which expand to their exec path,
            rendered lazily.

    Returns:
        A struct with methods:
            expand(args, input, split = False): expands make variables and
                location expressions in input and adds the result to the
                Args object args, as a single argument or, with split =
                True, as one argument per space-separated chunk of the
                expanded string.
            supports_path_mapping(): returns whether all expansions so far
                are compatible with path mapping; use it to gate the
                "supports-path-mapping" execution requirement of the
                consuming action.
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

# Sentinel for the rule's output directory, resolved to the parent directory
# of the anchor file, which always lives at the package's root in the output
# tree.
_RULEDIR = struct(expanders_ruledir = True)

def _genrule_vars(outs = [], inputs = []):
    """Returns extra_vars with genrule-style make variables.

    Provides $@ / $(@) (only with exactly one out), $(<) (only with exactly
    one input), $(@D) and $(RULEDIR) with genrule semantics. The values
    retain the given Files and render lazily, so they are path mapped.
    Referencing $@ with multiple outs or $(<) with multiple inputs fails
    with "$(@) not defined" / "$(<) not defined".

    Args:
        outs: The list of output Files backing $@ and $(@D).
        inputs: The list of input Files backing $(<).

    Returns:
        A dict to pass (possibly after overlaying additional variables) as
        the extra_vars parameter of expanders.make.
    """
    vars = {"RULEDIR": _RULEDIR}
    if len(outs) == 1:
        vars["@"] = outs[0]
        vars["@D"] = outs[0] if outs[0].is_directory else (outs[0], "dirname")
    else:
        vars["@D"] = _RULEDIR
    if len(inputs) == 1:
        vars["<"] = inputs[0]
    return vars

expanders = struct(
    make = _expander_init,
    genrule_vars = _genrule_vars,
)
