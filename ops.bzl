load(":parse.bzl", "LIT", "VAR", "parse")

visibility("private")

# Args token encoding, chosen to minimize retained analysis-phase memory. A
# token is one of:
#   "..."                    literal text, "$$" unescaped lazily
#   File                     exec path of a single file ($(execpath), $(location))
#   (File, "r")              runfiles path of a single file ($(rootpath))
#   (File, "R", ws_name)     rlocation path of a single file ($(rlocationpath))
#   (File, "b")              root path of a file ($(BINDIR), $(GENDIR))
#   ((File, ...), tag[, ws]) plural variants, space-joined and sorted
#   (input, val0, val1, ...) a composite argument: the original input string
#                            followed by one value per expansion site
#
# A composite token retains nothing but the original (attribute) string and
# the resolved values: rendering re-parses the input with the exact same
# parse() that resolved it during analysis (a pure function of the string),
# takes the literal segments from the scan (unescaping "$$") and substitutes
# the retained values for the variable and location sites in order. Since
# the re-parse also recovers each site's location function, site values
# carry no mode tags: exec and rootpath sites store a bare File, plural
# sites a bare tuple of Files (only rlocation sites keep their tagged form,
# as the workspace name is data). Make variable sites store their value as a
# bare string, appended verbatim ("$$" in values is unescaped eagerly during
# analysis since value pieces are fresh strings anyway), as an anchor pair
# (File, "b"), or - when a value resolved to several pieces - as a tuple of
# such pieces. Composite tokens have length >= 2 and a string head, which no
# other token shape has.
#
# All paths are computed inside the map_each callbacks below, which Bazel
# evaluates when the action's command line is expanded. File.path,
# File.short_path and File.root.path are therefore never materialized during
# analysis and, under --experimental_output_paths=strip, automatically
# reflect the path mapper of the consuming action.

def expand_token(token):
    """map_each callback turning a token into its expansion."""
    token_type = type(token)
    if token_type != "tuple":
        return _render_value(token)
    if len(token) >= 2 and type(token[0]) == "string":
        return _render_composite(token)
    return _render_value(token)

def expand_token_split(token):
    """map_each callback rendering a composite token into one string per space-separated chunk.

    Returning a list makes Args emit multiple arguments for a single token,
    which matches splitting the eagerly expanded string exactly - including
    plural expansions embedded in larger arguments.
    """
    return [chunk for chunk in _render_composite(token).split(" ") if chunk]

def _render_composite(token):
    input = token[0]
    parts = []
    next_val = 1
    for kind, start, end, payload in parse(input):
        if kind == LIT:
            lit = input[start:end]
            parts.append(lit.replace("$$", "$") if "$" in lit else lit)
            continue
        val = token[next_val]
        next_val += 1
        if kind == VAR:
            parts.append(_render_var_value(val))
        else:
            parts.append(_render_location_value(payload[0], val))
    return "".join(parts)

def _render_var_value(val):
    if type(val) == "string":
        # Verbatim: "$$" in make variable values is unescaped eagerly.
        return val
    if type(val[0]) == "File":
        # An anchor pair (file, "b") standing in for the output directory.
        return val[0].root.path
    parts = []
    for piece in val:
        if type(piece) == "string":
            parts.append(piece)
        else:
            parts.append(piece[0].root.path)
    return "".join(parts)

# The name of the main repository's runfiles directory under Bzlmod. When
# the rule's workspace name matches (pretty much always), rlocation site
# values in composites drop their tagged form and the renderer substitutes
# this constant; other workspace names keep the tagged form carrying the
# name as data.
MAIN_WORKSPACE = "_main"

def _render_location_value(fn, val):
    if fn == "rlocationpath" or fn == "rlocationpaths":
        if type(val) == "File":
            return rlocationpath(val, MAIN_WORKSPACE)
        if val[1] == "R" or type(val[0]) == "tuple":
            # Tagged forms carrying a non-default workspace name.
            return _render_value(val)

        # A bare tuple of Files (two or more; singletons strip to a File).
        return " ".join(sorted([rlocationpath(f, MAIN_WORKSPACE) for f in val]))
    if type(val) == "File":
        # Singular sites (and plural expansions of a single file).
        return callable_path(val.short_path if fn == "rootpath" else val.path)
    if fn == "rootpaths":
        return " ".join(sorted([callable_path(f.short_path) for f in val]))
    return " ".join(sorted([callable_path(f.path) for f in val]))

def _render_value(token):
    token_type = type(token)
    if token_type == "string":
        return token.replace("$$", "$") if "$" in token else token
    if token_type == "File":
        return callable_path(token.path)
    head = token[0]
    if len(token) == 1:
        return head
    tag = token[1]
    if type(head) == "File":
        if tag == "r":
            return callable_path(head.short_path)
        if tag == "R":
            return rlocationpath(head, token[2])
        return head.root.path
    if tag == "e":
        return " ".join(sorted([callable_path(f.path) for f in head]))
    if tag == "r":
        return " ".join(sorted([callable_path(f.short_path) for f in head]))
    return " ".join(sorted([rlocationpath(f, token[2]) for f in head]))

def callable_path(path):
    # Native location expansion returns PathFragment.getCallablePathString(),
    # which prepends "./" to paths that do not contain a "/". Plural
    # expansions sort after this transformation.
    return path if "/" in path else "./" + path

def rlocationpath(file, workspace_name):
    short_path = file.short_path
    if short_path.startswith("../"):
        return short_path[3:]
    return workspace_name + "/" + short_path

def root_token(anchor_file):
    return (anchor_file, "b")

def location_token(fn, files, workspace_name):
    # A plural exec path expansion of a single file renders exactly like the
    # singular form (sorting and joining are no-ops), so it can use the
    # cheaper bare-File encoding and the emission strategies enabled by it.
    if fn == "location" or fn == "execpath" or ((fn == "locations" or fn == "execpaths") and len(files) == 1):
        return files[0]
    elif fn == "rootpath":
        return (files[0], "r")
    elif fn == "rlocationpath":
        return (files[0], "R", workspace_name)
    elif fn == "locations" or fn == "execpaths":
        return (files, "e")
    elif fn == "rootpaths":
        return (files, "r")
    else:
        return (files, "R", workspace_name)
