def _expander_expand(args, input):
    pass

def _expander_init(args, targets = []):
    self = struct(
        expand = lambda input: _expander_expand(args, input),
    )
    return self

expanders = struct(
    make = _expander_init,
)
