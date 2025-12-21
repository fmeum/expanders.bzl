def _unescape(s):
    return s.replace("$$", "$")

def _error(ctx, input):
    # Let Bazel handle the error case.
    ctx.expand_location(ctx.expand_make_variables("expand", input, {}))

def _expander_preexpand(ctx, args, input):
    if "$" not in input:
        args.add(input)
        return

    needs_unescaping = False
    segments = []
    i = 0
    n = len(input)
    for _ in range(n):
        if i >= n:
            break
        if input[i] != "$":
            i = input.find("$", i + 1)
            continue
        i += 1
        c = input[i]
        if c == "$":
            needs_unescaping = True
            i += 1
        elif c == "(":
            segments.append((i - 1, needs_unescaping))
            needs_unescaping = False
            j = input.find(")", i + 1)
            if j == -1:
                _error(ctx, input)
                return
        else:
            _error(ctx, input)
            return
    segments.append((n, needs_unescaping))

    if needs_unescaping:
        args.add_all([input], map_each = _unescape)

def _expander_init(ctx, args, targets = []):
    self = struct(
        expand = lambda input: _expander_preexpand(ctx, args, input),
    )
    return self

expanders = struct(
    make = _expander_init,
)
