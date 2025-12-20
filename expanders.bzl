def _unescape(s):
    return s.replace("$$", "$")

def _expander_preexpand(args, input):
    if "$" not in input:
        args.add(input)
        return

    needs_unescaping = False
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
        else:
            continue

    if needs_unescaping:
        args.add_all([input], map_each = _unescape)

def _expander_init(args, targets = []):
    self = struct(
        expand = lambda input: _expander_preexpand(args, input),
    )
    return self

expanders = struct(
    make = _expander_init,
)
