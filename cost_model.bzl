load(":ops.bzl", "expand_token")

visibility("private")

# Chooses the emission strategy that retains the least memory, based on the
# cost model derived from Bazel's Args/StarlarkCustomCommandLine internals in
# docs/memory.md:
#
#   * Args stores one flat Object[] per built command line; every scalar
#     args.add costs one 4-byte slot and interns strings, deduplicating equal
#     content across all actions and targets in the build.
#   * add_all/add_joined cost 3 to n + 4 slots plus the token objects, but
#     never intern and are the only way to defer path computation to
#     execution time (and thus to support path mapping).
#
# Tokens that do not reference any File (literals and make variable values)
# expand to target-independent content, so expanding them eagerly costs at
# most one interned string per unique (input, configuration) pair in the
# entire build - strictly less than the token encoding. Everything else stays
# lazy: paths never materialize during analysis and map_each picks up path
# mapping at execution time.

def emit(args, tokens):
    """Adds the expansion described by tokens to args as a single argument."""
    lazy = False
    for token in tokens:
        token_type = type(token)
        if token_type != "string" and not (token_type == "tuple" and len(token) == 1):
            lazy = True
            break

    if not lazy:
        # expand_token is pure and cheap for literal and make variable tokens,
        # so evaluating it during analysis yields exactly the same bytes as
        # the lazy path. Single tokens are added directly to reuse the
        # existing string instance where possible.
        if len(tokens) == 1:
            args.add(expand_token(tokens[0]))
        else:
            args.add("".join([expand_token(token) for token in tokens]))
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
