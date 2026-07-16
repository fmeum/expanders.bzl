load(":ops.bzl", "expand_token")

visibility("private")

# Chooses the emission strategy that retains the least memory, based on the
# cost model derived from Bazel's Args/StarlarkCustomCommandLine internals in
# docs/memory.md:
#
#   * Args stores one flat Object[] per built command line; every scalar
#     args.add costs one 4-byte slot and interns strings, deduplicating equal
#     content across all actions and targets in the build.
#   * args.add(file) and args.add(file, format = ...) keep the File and
#     format the exec path lazily (SingleFormattedArg), so they are path
#     mapping aware while retaining only 1 or 3 slots plus the format string.
#   * add_all/add_joined cost 3 to n + 4 slots plus the token objects and
#     never intern, but are the only way to defer computation of paths other
#     than exec paths (and of joined plural expansions) to execution time.
#
# Strategies, in order of preference:
#
#   1. All tokens are static (literals and make variable values): expand
#      eagerly into a single interned string. Such arguments contain nothing
#      path-mappable, and equal content is retained once per build.
#   2. Exactly one dynamic token, which is a singular exec path whose default
#      stringification matches location expansion: emit args.add(file) or
#      args.add(file, format = ...) with the static tokens folded into the
#      format string. Directories, which args.add rejects, use a singleton
#      args.add_all(..., expand_directories = False) with format_each
#      instead. No tuples and at most one fresh string are retained, and the
#      exec path is still rendered lazily and path mapped.
#   3. Otherwise: the generic lazy token encoding via map_each.

def _is_static(token):
    token_type = type(token)
    return token_type == "string" or (token_type == "tuple" and len(token) == 1)

def _format_piece(token):
    if type(token) == "File":
        return "%s"
    return expand_token(token).replace("%", "%%")

def emit(args, tokens):
    """Adds the expansion described by tokens to args as a single argument."""
    dynamic = 0
    file_token = None
    for token in tokens:
        if not _is_static(token):
            dynamic += 1
            if type(token) == "File":
                file_token = token

    if dynamic == 0:
        # expand_token is pure and cheap for static tokens, so evaluating it
        # during analysis yields exactly the same bytes as the lazy path.
        # Single tokens are added directly to reuse the existing string
        # instance where possible.
        if len(tokens) == 1:
            args.add(expand_token(tokens[0]))
        else:
            args.add("".join([expand_token(token) for token in tokens]))
    elif dynamic == 1 and file_token != None and "/" in file_token.path:
        # Args stringifies a File as its raw exec path, which matches
        # location expansion except for paths without a "/", which get a
        # "./" prefix there (those stay on the generic lazy path below).
        if file_token.is_directory:
            # args.add rejects directories, but a singleton add_all with
            # expand_directories = False stringifies them identically, with
            # format_each taking the place of format.
            if len(tokens) == 1:
                args.add_all([file_token], expand_directories = False)
            else:
                args.add_all(
                    [file_token],
                    format_each = "".join([_format_piece(token) for token in tokens]),
                    expand_directories = False,
                )
        elif len(tokens) == 1:
            args.add(file_token)
        else:
            args.add(
                file_token,
                format = "".join([_format_piece(token) for token in tokens]),
            )
    elif len(tokens) == 1:
        args.add_all(tokens, map_each = expand_token, expand_directories = False)
    else:
        args.add_joined(
            tokens,
            join_with = "",
            map_each = expand_token,
            omit_if_empty = False,
            expand_directories = False,
        )
