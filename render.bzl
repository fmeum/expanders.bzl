"""Execution-time rendering of expansion tokens.

Only the map_each callbacks and their helpers live here: retained Args pin
this module through the callback references, so it contains no analysis-time
code.

Token shapes:

    "..."                        literal text; "$$" unescaped at render time
    File                         singular exec path
    (File, "rootpath")           singular runfiles path
    (File, "rlocationpath", ws)  singular rlocation path, non-default ws
    (File, "root")               root path ($(BINDIR), $(GENDIR))
    (File, "dirname")            containing directory ($(@D), $(RULEDIR))
    ((File, ...), tag[, ws])     plural forms, space-joined and sorted
    (input, val0, val1, ...)     composite argument

A composite token holds the original input string and one value per variable
or location site. Rendering re-parses the input with the same parse() that
resolved it during analysis, takes the literal segments from the scan and
substitutes the values in site order. Since the re-parse recovers each
site's location function, location values are untagged (a bare File or files
tuple); only rlocation values for main-repository files under a workspace
name other than MAIN_WORKSPACE keep the tagged form. Make variable values
are verbatim strings (unescaped during analysis), Files (rendered as the raw
exec path), (File, "root"/"dirname") pairs, or a ("group", ...) tuple of
such pieces. Composite tokens are the only tuples with a string head.

Paths are computed only inside these callbacks, when the command line is
expanded, and thus reflect the consuming action's path mapper.
"""

load(":parse.bzl", "LIT", "VAR", "parse")

visibility("private")

# The main repository's workspace name under Bzlmod. Tokens only carry a
# workspace name when it differs.
MAIN_WORKSPACE = "_main"

def expand_token(token):
    """map_each callback rendering a token as a single argument."""
    token_type = type(token)
    if token_type != "tuple":
        return _render_value(token)
    if len(token) >= 2 and type(token[0]) == "string":
        return _render_composite(token)
    return _render_value(token)

def expand_token_split(token):
    """map_each callback rendering a composite token as one argument per chunk.

    The returned list makes Args emit multiple arguments, matching a split
    of the eagerly expanded string.
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
        parts = []
        for i in range(1, len(val)):
            parts.append(_render_var_piece(val[i]))
        return "".join(parts)
    return _render_var_piece(val)

def _render_var_piece(piece):
    piece_type = type(piece)
    if piece_type == "string":
        return piece
    if piece_type == "File":
        return piece.path
    if piece[1] == "dirname":
        path = piece[0].path
        return path[:path.rfind("/")]
    return piece[0].root.path

def _render_location_value(fn, val):
    if fn == "rlocationpath" or fn == "rlocationpaths":
        if type(val) == "File":
            return rlocationpath(val, MAIN_WORKSPACE)
        if val[1] == "rlocationpath" or type(val[0]) == "tuple":
            # A tagged value; a bare files tuple has a File at index 1 and
            # always at least two elements (singletons strip to a File).
            return _render_value(val)
        return " ".join(sorted([rlocationpath(f, MAIN_WORKSPACE) for f in val]))
    if type(val) == "File":
        return callable_path(val.short_path if fn == "rootpath" else val.path)
    if fn == "rootpaths":
        return " ".join(sorted([callable_path(f.short_path) for f in val]))
    return " ".join(sorted([callable_path(f.path) for f in val]))

def _render_value(token):
    """Renders a non-composite token; tagged forms are always rlocations here."""
    token_type = type(token)
    if token_type == "string":
        return token.replace("$$", "$") if "$" in token else token
    if token_type == "File":
        return callable_path(token.path)
    head = token[0]
    if type(head) == "File":
        return rlocationpath(head, token[2])
    return " ".join(sorted([rlocationpath(f, token[2]) for f in head]))

# map_each callbacks for whole-argument tokens, which are emitted as a bare
# File or files tuple with the callback selecting the rendering.

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
    # Native location expansion returns PathFragment#getCallablePathString,
    # which prepends "./" to paths without a "/"; plural forms sort after
    # this transformation.
    return path if "/" in path else "./" + path

def rlocationpath(file, workspace_name):
    short_path = file.short_path
    if short_path.startswith("../"):
        return short_path[3:]
    return workspace_name + "/" + short_path
