load(":ops.bzl", "expand_token", "expand_token_split")

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
    val_type = type(val)
    return val_type == "string" or (val_type == "tuple" and len(val) == 1)

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

def emit(args, input, items, split):
    """Adds the expansion of input, resolved into items, to args.

    items is a list of ("lit", start, end) and ("site", start, end, vals)
    entries in input order, where vals are simple ops.bzl tokens.
    """
    vals = []
    static = True
    for item in items:
        if item[0] != "site":
            continue
        for val in item[3]:
            if not _is_static(val):
                static = False
        site_vals = item[3]
        vals.append(site_vals[0] if len(site_vals) == 1 else (tuple(site_vals),))

    if static:
        pieces = []
        for item in items:
            if item[0] == "lit":
                pieces.append(_unescape(input[item[1]:item[2]]))
            else:
                for val in item[3]:
                    pieces.append(expand_token(val))

        # A single piece is added directly to reuse the existing string
        # instance where possible; args.add interns the result either way.
        text = pieces[0] if len(pieces) == 1 else "".join(pieces)
        if not split:
            args.add(text)
        else:
            for chunk in text.split(" "):
                if chunk:
                    args.add(chunk)
    elif not split and len(items) == 1 and (type(vals[0]) != "tuple" or len(vals[0]) > 1):
        # The whole argument is a single dynamic value (a lone site with one
        # value; groups are 1-tuples and take the composite path).
        _add_single(args, vals[0])
    else:
        args.add_all(
            [tuple([input] + vals)],
            map_each = expand_token_split if split else expand_token,
            expand_directories = False,
        )
