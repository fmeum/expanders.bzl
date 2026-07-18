visibility("private")

# Token kinds produced by parse(). All tokens carry [start, end) offsets into
# the input so that no substrings need to be created or retained; consumers
# slice the input on demand.
LIT = 0  # a literal segment, potentially containing "$$" escapes
VAR = 1  # a make variable reference; payload: the name
LOC = 2  # a location function; payload: a (function name, label string) tuple

# The location functions supported by ctx.expand_location.
LOCATION_FUNCTIONS = {
    "execpath": None,
    "execpaths": None,
    "location": None,
    "locations": None,
    "rlocationpath": None,
    "rlocationpaths": None,
    "rootpath": None,
    "rootpaths": None,
}

def parse(input):
    """Tokenizes a string with make variable and location references.

    The result is a list of (kind, start, end, payload) tuples, where
    [start, end) is the token's extent in input (for VAR and LOC, including
    the "$(...)" syntax) and payload is None for LIT.

    Fails with errors matching those of the native expansion logic, which is
    ctx.expand_make_variables applied to the result of ctx.expand_location.
    """
    tokens = []
    lit_start = 0
    n = len(input)
    i = 0

    # Starlark has no while loop; each iteration consumes at least one "$", so
    # n iterations are always enough.
    for _ in range(n):
        j = input.find("$", i)
        if j == -1:
            break
        if j + 1 == n:
            fail("unterminated $")
        c = input[j + 1]
        if c == "$":
            # An escaped "$", kept in the literal segment and unescaped only
            # when the command line is expanded.
            i = j + 2
        elif c == "(":
            k = input.find(")", j + 2)
            if k == -1:
                fail("unterminated variable reference")
            if j > lit_start:
                tokens.append((LIT, lit_start, j, None))
            inner = input[j + 2:k]
            space = inner.find(" ")
            if space == -1:
                tokens.append((VAR, j, k + 1, inner))
            elif inner[:space] in LOCATION_FUNCTIONS:
                tokens.append((LOC, j, k + 1, (inner[:space], inner[space + 1:])))
            else:
                # ctx.expand_location leaves unknown functions alone, then
                # ctx.expand_make_variables fails on them with this error.
                fail("$(%s) not defined" % inner[:space])
            i = k + 1
            lit_start = i
        else:
            # A single-character variable reference like $@.
            if j > lit_start:
                tokens.append((LIT, lit_start, j, None))
            tokens.append((VAR, j, j + 2, c))
            i = j + 2
            lit_start = i

    if lit_start < n:
        tokens.append((LIT, lit_start, n, None))
    return tokens
