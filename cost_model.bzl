load(":ops.bzl", "callable_path", "expand_token", "rlocationpath")

visibility("private")

# Chooses the emission strategy that retains the least memory, based on the
# cost model derived from Bazel's Args/StarlarkCustomCommandLine internals in
# docs/memory.md:
#
#   * Args stores one flat Object[] per built command line; every scalar
#     args.add costs one 4-byte slot and interns strings, deduplicating equal
#     content across all actions and targets in the build.
#   * Spans reference the original input string (retained by the rule's
#     attribute anyway) plus cached Starlark ints, so composite arguments
#     retain no literal text at all.
#   * add_all costs 2 to 3 slots for the singleton uses here and never
#     interns, but defers all path computation to execution time.
#
# Strategies:
#
#   1. All content is static (literals and make variable values): expand
#      eagerly into a single interned string. Such arguments contain nothing
#      path-mappable, and equal content is retained once per build.
#   2. The whole argument is a single dynamic value: args.add(file) for
#      exec paths (1 slot; directories via a singleton add_all with
#      expand_directories = False since args.add rejects them, 2 slots),
#      otherwise a singleton add_all with map_each (3 slots).
#   3. Otherwise: one span token rendered by map_each.
#
# With split = True, the input is additionally broken into one argument per
# space-separated chunk: chunk boundaries come from spaces in literal
# segments and in (analysis-known) make variable values, while a plural
# location expansion that forms a chunk on its own fans out into one
# argument per file. All strategies above then apply per chunk.

def _is_static(val):
    val_type = type(val)
    return val_type == "string" or (val_type == "tuple" and len(val) == 1)

def _is_plural(val):
    return type(val) == "tuple" and len(val) >= 2 and type(val[0]) == "tuple"

def _span(input, chunk_start, chunk_end, sites):
    parts = [input, chunk_start, chunk_end]
    for site in sites:
        parts.append(site[0])
        parts.append(site[1])
        parts.append(site[2])
    return tuple(parts)

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

def _exec_sort_key(f):
    return callable_path(f.path)

def _root_sort_key(f):
    return callable_path(f.short_path)

def _add_fanout(args, val):
    """Emits a plural location value as one argument per file.

    Files are ordered by their (unmapped) rendered path, matching the order
    native expansion joins them in.
    """
    tag = val[1]
    if tag == "e":
        values = sorted(val[0], key = _exec_sort_key)
    elif tag == "r":
        values = [(f, "r") for f in sorted(val[0], key = _root_sort_key)]
    else:
        ws = val[2]
        values = [(f, "R", ws) for f in sorted(val[0], key = lambda f: rlocationpath(f, ws))]
    args.add_all(values, map_each = expand_token, expand_directories = False)

def _flatten_sites(items):
    # Flattens per-site value lists into (start, end, val) triples, with
    # values after the first spliced in at the site's end as empty ranges.
    sites = []
    static = True
    for item in items:
        if item[0] != "site":
            continue
        first = True
        for val in item[3]:
            if not _is_static(val):
                static = False
            sites.append((item[1] if first else item[2], item[2], val))
            first = False
    return sites, static

def _unescape(s):
    return s.replace("$$", "$") if "$" in s else s

def emit(args, input, items, split):
    """Adds the expansion of input, resolved into items, to args.

    items is a list of ("lit", start, end) and ("site", start, end, vals)
    entries in input order, where vals are simple ops.bzl tokens.
    """
    if split:
        _emit_split(args, input, items)
    else:
        _emit_arg(args, input, items)

def _emit_arg(args, input, items):
    sites, static = _flatten_sites(items)
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
        args.add(pieces[0] if len(pieces) == 1 else "".join(pieces))
    elif len(items) == 1 and len(sites) == 1:
        _add_single(args, sites[0][2])
    else:
        args.add_all(
            [_span(input, 0, len(input), sites)],
            map_each = expand_token,
            expand_directories = False,
        )

def _emit_split(args, input, items):
    # Chunk atoms: ("lit", a, b) is the input fragment [a, b);
    # ("txt", s, e, text) is static text replacing the input range [s, e);
    # ("dyn", s, e, val) is a dynamic value replacing [s, e).
    chunk = []
    for item in items:
        if item[0] == "lit":
            pos = item[1]
            end = item[2]
            for _ in range(end - pos + 1):
                if pos >= end:
                    break
                space = input.find(" ", pos, end)
                if space == -1:
                    chunk.append(("lit", pos, end))
                    break
                if space > pos:
                    chunk.append(("lit", pos, space))
                chunk = _flush_chunk(args, input, chunk)
                pos = space + 1
            continue
        first = True
        for val in item[3]:
            start = item[1] if first else item[2]
            first = False
            if not _is_static(val):
                chunk.append(("dyn", start, item[2], val))
                continue
            text = expand_token(val)
            if " " not in text:
                if text or start != item[2]:
                    chunk.append(("txt", start, item[2], text))
                continue
            for i, fragment in enumerate(text.split(" ")):
                if i > 0:
                    chunk = _flush_chunk(args, input, chunk)
                if fragment or (i == 0 and start != item[2]):
                    chunk.append(("txt", start if i == 0 else item[2], item[2], fragment))
    _flush_chunk(args, input, chunk)

def _flush_chunk(args, input, chunk):
    if not chunk:
        return []
    dyns = [atom for atom in chunk if atom[0] == "dyn"]
    if not dyns:
        pieces = []
        for atom in chunk:
            if atom[0] == "lit":
                pieces.append(_unescape(input[atom[1]:atom[2]]))
            else:
                pieces.append(atom[3])
        text = pieces[0] if len(pieces) == 1 else "".join(pieces)
        if text:
            args.add(text)
        return []
    if len(chunk) == 1 and _is_plural(dyns[0][3]):
        _add_fanout(args, dyns[0][3])
        return []
    for atom in dyns:
        if _is_plural(atom[3]):
            fail(("a plural location expansion cannot be combined with other content in a single " +
                  "argument when split = True: %s") % input)
    if len(chunk) == 1:
        _add_single(args, dyns[0][3])
        return []
    sites = [
        (atom[1], atom[2], atom[3] if atom[0] == "dyn" else (atom[3],))
        for atom in chunk
        if atom[0] != "lit"
    ]
    args.add_all(
        [_span(input, chunk[0][1], chunk[-1][2], sites)],
        map_each = expand_token,
        expand_directories = False,
    )
    return []
