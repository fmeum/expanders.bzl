"""Benchmark rules comparing retained heap of lazy vs eager expansion.

Each rule registers a single ctx.actions.write action whose Args content is
retained in Skyframe. Building N instances of each variant with --nobuild in
a fresh server and comparing `jcmd <server_pid> GC.class_histogram` against
the `null_expand` baseline (same attributes, no expansion) isolates the
retained cost of the expansion strategy. See docs/memory.md for the model,
the measured numbers and reproduction steps.
"""

load("@expanders.bzl", "expanders")

def expand_strings(i):
    """100 strings: 50 composite, 25 single-token, 25 plural, unique per target."""
    return (
        ["--t%d.opt%d=$(execpath :gen%d.txt)" % (i, j, j % 8) for j in range(50)] +
        ["$(execpath :gen%d.txt) #%d.%d" % (j % 8, i, j) for j in range(25)] +
        ["$(execpaths :group) #%d.%d" % (i, j) for j in range(25)]
    )

_ATTRS = {
    "expand": attr.string_list(),
    "srcs": attr.label_list(allow_files = True),
    "data": attr.label_list(allow_files = True),
}

def _write(ctx, args):
    out = ctx.actions.declare_file(ctx.label.name + ".out")
    ctx.actions.write(out, args)
    return [DefaultInfo(files = depset([out]))]

def _null_impl(ctx):
    args = ctx.actions.args().set_param_file_format("multiline")
    for input in ctx.attr.expand:
        args.add(input)
    return _write(ctx, args)

null_expand = rule(implementation = _null_impl, attrs = _ATTRS)

def _lazy_impl(ctx):
    expander = expanders.make(ctx, targets = ctx.attr.srcs + ctx.attr.data)
    args = ctx.actions.args().set_param_file_format("multiline")
    for input in ctx.attr.expand:
        expander.expand(args, input)
    return _write(ctx, args)

lazy_expand = rule(implementation = _lazy_impl, attrs = _ATTRS)

def _eager_impl(ctx):
    targets = ctx.attr.srcs + ctx.attr.data
    args = ctx.actions.args().set_param_file_format("multiline")
    for input in ctx.attr.expand:
        args.add(ctx.expand_make_variables("expand", ctx.expand_location(input, targets), {}))
    return _write(ctx, args)

eager_expand = rule(implementation = _eager_impl, attrs = _ATTRS)
