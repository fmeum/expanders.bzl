"""TODO: bgorshenev - Write module docstring."""

load("//third_party/bazel_rules/expanders:expanders.bzl", "expanders")

# Translate output_list into an iterable that this can handle.
def _iterable_outputs(outputs):
    outs = []
    for name in dir(outputs):
        value = getattr(outputs, name)
        if type(value) == "list":
            outs.extend(value)
        else:
            outs.append(value)
    return outs

def _starlark_genrule_impl(ctx):
    outs = _iterable_outputs(ctx.outputs)
    expander = expanders.make(ctx, [], expanders.genrule_vars(outs, ctx.files.srcs))
    args = ctx.actions.args()
    expander.expand(args, ctx.attr.cmd)
    if ctx.attr.require_path_mapping and not expander.supports_path_mapping():
        fail("Command does not support path mapping.")
    ctx.actions.run_shell(
        outputs = outs,
        inputs = ctx.files.srcs,
        tools = ctx.files.tools,
        arguments = [args],
        command = 'bash -c "${@}"',
        env = ctx.attr.env,
        mnemonic = ctx.attr.mnemonic,
    )
    return [DefaultInfo(
        files = depset(outs),
    )]

_starlark_genrule = rule(
    implementation = _starlark_genrule_impl,
    output_to_genfiles = True,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
        ),
        "outs": attr.output_list(
            mandatory = True,
        ),
        "cmd": attr.string(
            mandatory = True,
        ),
        "env": attr.string_list_dict(),
        "tools": attr.label_list(
            allow_files = True,
            cfg = "exec",
        ),
        "mnemonic": attr.string(
            mandatory = True,
        ),
        "require_path_mapping": attr.bool(default = True),
    },
)

starlark_genrule = struct(
    genrule = _starlark_genrule,
)
