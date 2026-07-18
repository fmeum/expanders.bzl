load(":ops.bzl", "MAIN_WORKSPACE", "expand_token", "expand_token_split")

visibility("private")

# Chooses the emission strategy that retains the least memory, based on the
# cost model derived from Bazel's Args/StarlarkCustomCommandLine internals in
# docs/memory.md:
#
#   * Args stores one flat Object[] per built command line; every scalar
#     args.add costs one 4-byte slot and interns strings, deduplicating equal
#     content across all actions and targets in the build.
#   * Composite tokens reference the original input string (retained by the
#     rule's attribute anyway) plus the resolved values; the expansion sites
#     are recovered at rendering time by re-running the same parse() on the
#     input, so neither literal text nor offsets are retained.
#   * add_all costs 2 to 3 slots for the singleton uses here and never
#     interns, but defers all path computation to execution time.
#
# Strategies:
#
#   1. All content is static (literals and make variable values): expand
#      eagerly into a single interned string (or, with split = True, one
#      interned string per space-separated chunk). Such arguments contain
#      nothing path-mappable, and equal content is retained once per build.
#   2. The whole argument is a single dynamic value: args.add(file) for
#      exec paths (1 slot; directories via a singleton add_all with
#      expand_directories = False since args.add rejects them, 2 slots),
#      otherwise a singleton add_all with map_each (3 slots).
#   3. Otherwise: one composite token (input, val0, val1, ...) rendered by
#      map_each. With split = True, the rendering callback returns one
#      string per space-separated chunk of the expanded string, which Args
#      fans out into multiple arguments - byte-identical to splitting the
#      eager expansion, including plural expansions embedded in larger
#      arguments.

def _is_static(val):
    # Make variable values are stored as bare (eagerly unescaped) strings;
    # everything else is dynamic.
    return type(val) == "string"

def _add_single(args, val):
    """Emits a single dynamic value as one argument with the cheapest encoding."""
    if type(val) == "File":
        if val.is_directory:
            # args.add rejects directories, but a singleton add_all with
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

def _unescape(s):
    return s.replace("$$", "$") if "$" in s else s

def _strip(val):
    # Composite sites are rendered with knowledge of the site's location
    # function recovered by the re-parse, so mode tags are dropped: rootpath
    # sites store a bare File, plural exec/rootpath sites a bare tuple of
    # Files. rlocation values keep their tagged form (the workspace name is
    # data), as do anchor pairs (whose site is a make variable reference
    # that cannot be re-resolved purely).
    if type(val) != "tuple":
        return val
    if len(val) == 2 and val[1] == "r":
        return val[0]
    if len(val) == 2 and val[1] == "e":
        return val[0]
    if len(val) == 3 and val[1] == "R":
        # The workspace name is only consulted when rendering the rlocation
        # path of a file in the main repository, so it need not be stored
        # when it is the Bzlmod default (the renderer substitutes the
        # constant) or when the files are all external (runfiles paths
        # starting with "../" never use it). Singleton plurals strip all the
        # way to a File so that bare files tuples are always distinguishable
        # from the tagged forms.
        head = val[0]
        if type(head) == "File":
            if val[2] == MAIN_WORKSPACE or head.short_path.startswith("../"):
                return head
            return val
        if val[2] == MAIN_WORKSPACE or _all_external(head):
            return head if len(head) > 1 else head[0]
    return val

def _all_external(files):
    for f in files:
        if not f.short_path.startswith("../"):
            return False
    return True

def emit(args, input, items, split):
    """Adds the expansion of input, resolved into items, to args.

    items is a list of ("lit", start, end) and ("site", start, end, vals)
    entries in input order, where vals are simple ops.bzl tokens.
    """
    site_items = [item for item in items if item[0] == "site"]
    static = True
    for item in site_items:
        for val in item[3]:
            if not _is_static(val):
                static = False

    if static:
        pieces = []
        for item in items:
            if item[0] == "lit":
                pieces.append(_unescape(input[item[1]:item[2]]))
            else:
                # Value strings are already unescaped and render verbatim.
                pieces.extend(item[3])

        # A single piece is added directly to reuse the existing string
        # instance where possible; args.add interns the result either way.
        text = pieces[0] if len(pieces) == 1 else "".join(pieces)
        if not split:
            args.add(text)
        else:
            for chunk in text.split(" "):
                if chunk:
                    args.add(chunk)
    elif not split and len(items) == 1 and len(site_items[0][3]) == 1:
        # The whole argument is a single dynamic value; emitted in its
        # tagged form, which renders without re-parsing.
        _add_single(args, site_items[0][3][0])
    else:
        vals = []
        for item in site_items:
            site_vals = item[3]
            vals.append(_strip(site_vals[0]) if len(site_vals) == 1 else tuple(site_vals))
        args.add_all(
            [tuple([input] + vals)],
            map_each = expand_token_split if split else expand_token,
            expand_directories = False,
        )
