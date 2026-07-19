"""Execution-time rendering of expansion tokens.

Only the map_each callbacks and their helpers live here: the Args objects of
every rule using this library retain references to these functions, which
transitively pin their module. Keeping this module free of analysis-time
machinery keeps that footprint minimal.
"""

load(":parse.bzl", "LIT", "VAR", "parse")

visibility("private")

# Args token encoding, chosen to minimize retained analysis-phase memory. A
# token is one of:
#   "..."                    literal text, "$$" unescaped lazily
#   File                     exec path of a single file ($(execpath), $(location))
#   (File, "rootpath")       runfiles path of a single file ($(rootpath))
#   (File, "rlocationpath", ws)  rlocation path of a single file
#   (File, "root")           root path of a file ($(BINDIR), $(GENDIR))
#   (File, "dirname")        containing directory of a file ($(@D), $(RULEDIR))
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
# (File, "root"), a dirname pair (File, "dirname"), or - when a value
# resolved to several pieces - as a ("group", ...) tuple of such pieces. Composite tokens have length >= 2 and a string head, which no
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
    val_type = type(val)
    if val_type == "string" or val_type == "File":
        return _render_var_piece(val)
    if val[0] == "group":
        # A group of pieces from a value that resolved to several tokens.
        parts = []
        for i in range(1, len(val)):
            parts.append(_render_var_piece(val[i]))
        return "".join(parts)
    return _render_var_piece(val)

def _render_var_piece(piece):
    piece_type = type(piece)
    if piece_type == "string":
        # Verbatim: "$$" in make variable values is unescaped eagerly.
        return piece
    if piece_type == "File":
        # A File-valued make variable renders as its raw exec path.
        return piece.path
    if piece[1] == "dirname":
        # The directory containing the file ($(@D), $(RULEDIR)).
        path = piece[0].path
        return path[:path.rfind("/")]

    # An anchor pair (file, "root") standing in for the output directory.
    return piece[0].root.path

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
        if val[1] == "rlocationpath" or type(val[0]) == "tuple":
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

    # Only rlocation values for main-repository files under a non-default
    # workspace name remain tagged: (file, "rlocationpath", ws) or
    # ((files...), "rlocationpath", ws).
    head = token[0]
    if type(head) == "File":
        return rlocationpath(head, token[2])
    return " ".join(sorted([rlocationpath(f, token[2]) for f in head]))

# Render callbacks for whole-argument tokens: emitting a bare File or files
# tuple with the matching callback retains no tag tuple at all, and the
# callbacks are folded into the interned VectorArg for free.

def render_root_path(file):
    return file.root.path

def render_parent_dir(file):
    path = file.path
    return path[:path.rfind("/")]

def render_rootpath(file):
    return callable_path(file.short_path)

def render_rootpaths(files):
    return " ".join(sorted([callable_path(f.short_path) for f in files]))

def render_execpaths(files):
    return " ".join(sorted([callable_path(f.path) for f in files]))

def render_rlocationpath(file):
    return rlocationpath(file, MAIN_WORKSPACE)

def render_rlocationpaths(files):
    return " ".join(sorted([rlocationpath(f, MAIN_WORKSPACE) for f in files]))

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
