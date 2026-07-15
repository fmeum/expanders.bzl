visibility("private")

# Args token encoding, chosen to minimize retained analysis-phase memory. A
# token is one of:
#   "..."                    literal attribute substring, "$$" unescaped lazily
#   ("...",)                 verbatim string (a make variable value)
#   File                     exec path of a single file ($(execpath), $(location))
#   (File, "r")              runfiles path of a single file ($(rootpath))
#   (File, "R", ws_name)     rlocation path of a single file ($(rlocationpath))
#   (File, "b")              root path of a file ($(BINDIR), $(GENDIR))
#   ((File, ...), tag[, ws]) plural variants, space-joined and sorted
#
# All paths are computed inside the map_each callback below, which Bazel
# evaluates when the action's command line is expanded. File.path,
# File.short_path and File.root.path are therefore never materialized during
# analysis and, under --experimental_output_paths=strip, automatically
# reflect the path mapper of the consuming action.

def expand_token(token):
    """map_each callback turning a token into its expansion."""
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
            return _rlocationpath(head, token[2])
        return head.root.path
    if tag == "e":
        return " ".join(sorted([callable_path(f.path) for f in head]))
    if tag == "r":
        return " ".join(sorted([callable_path(f.short_path) for f in head]))
    return " ".join(sorted([_rlocationpath(f, token[2]) for f in head]))

def callable_path(path):
    # Native location expansion returns PathFragment.getCallablePathString(),
    # which prepends "./" to paths that do not contain a "/". Plural
    # expansions sort after this transformation.
    return path if "/" in path else "./" + path

def _rlocationpath(file, workspace_name):
    short_path = file.short_path
    if short_path.startswith("../"):
        return short_path[3:]
    return workspace_name + "/" + short_path

def var_token(value):
    return (value,)

def root_token(anchor_file):
    return (anchor_file, "b")

def location_token(fn, files, workspace_name):
    if fn == "location" or fn == "execpath":
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
