visibility("private")

# Args token encoding, chosen to minimize retained analysis-phase memory. A
# token is one of:
#   "..."                    literal text, "$$" unescaped lazily
#   ("...",)                 verbatim string (e.g. a make variable value)
#   File                     exec path of a single file ($(execpath), $(location))
#   (File, "r")              runfiles path of a single file ($(rootpath))
#   (File, "R", ws_name)     rlocation path of a single file ($(rlocationpath))
#   (File, "b")              root path of a file ($(BINDIR), $(GENDIR))
#   ((File, ...), tag[, ws]) plural variants, space-joined and sorted
#   span (see below)         a composite argument rendered from the original
#                            input string
#
# A span token references the original (attribute) string instead of
# retaining substrings of it:
#
#   (input, chunk_start, chunk_end, s0, e0, val0, s1, e1, val1, ...)
#
# It renders input[chunk_start:chunk_end] with each [s_i, e_i) range replaced
# by the rendering of val_i (one of the simple tokens above) and "$$"
# unescaped in the literal segments in between. Sites are in ascending order
# and may be empty (s_i == e_i) to splice in values without consuming input,
# e.g. the pieces of a make variable value split around the output directory.
# Retained memory: the input string is shared with the rule's attribute,
# Starlark ints below 100,000 are cached singletons, so a span costs its
# tuple plus any non-File values - independent of the length of the literal
# text. Spans have length >= 6 and a string head, which no other token shape
# has.
#
# All paths are computed inside the map_each callback below, which Bazel
# evaluates when the action's command line is expanded. File.path,
# File.short_path and File.root.path are therefore never materialized during
# analysis and, under --experimental_output_paths=strip, automatically
# reflect the path mapper of the consuming action.

def expand_token(token):
    """map_each callback turning a token into its expansion."""
    token_type = type(token)
    if token_type != "tuple":
        return _render_value(token)
    if len(token) >= 6 and type(token[0]) == "string":
        input = token[0]
        parts = []
        previous_end = token[1]
        num_sites = (len(token) - 3) // 3
        for i in range(num_sites):
            lit = input[previous_end:token[3 + 3 * i]]
            if lit:
                parts.append(lit.replace("$$", "$") if "$" in lit else lit)
            parts.append(_render_value(token[5 + 3 * i]))
            previous_end = token[4 + 3 * i]
        lit = input[previous_end:token[2]]
        if lit:
            parts.append(lit.replace("$$", "$") if "$" in lit else lit)
        return "".join(parts)
    return _render_value(token)

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

def var_token(value):
    return (value,)

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
