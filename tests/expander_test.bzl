load("@bazel_lib//lib:diff_test.bzl", "diff_test")
load("@expanders.bzl", "expanders")

def _do_expand_impl(ctx):
    # Expand with expanders.bzl.
    actual = ctx.actions.declare_file(ctx.label.name + ".actual")
    actual_args = ctx.actions.args()
    expander = expanders.make(
        actual_args,
        targets = ctx.attr.srcs + ctx.attr.data + ctx.outputs.outs,
    )
    for input in ctx.attr.expand:
        expander.expand(input)
    ctx.actions.write(
        output = actual,
        content = actual_args,
    )

    # Expand with native Bazel functionality.
    expected = ctx.actions.declare_file(ctx.label.name + ".expected")
    expected_args = ctx.actions.args()
    for input in ctx.attr.expand:
        expected_args.add(ctx.expand_location(input))
    ctx.actions.write(
        output = expected,
        content = expected_args,
    )

    return [
        OutputGroupInfo(
            actual = depset([actual]),
            expected = depset([expected]),
        ),
    ]

_do_expand = rule(
    implementation = _do_expand_impl,
    attrs = {
        "expand": attr.string_list(),
        "srcs": attr.label_list(allow_files = True),
        "data": attr.label_list(allow_files = True),
        "outs": attr.output_list(),
    },
)

def expander_test(name, **kwargs):
    _do_expand(
        name = name + "_impl",
        **kwargs
    )

    native.filegroup(
        name = name + "_actual",
        srcs = [name + "_impl"],
        output_group = "actual",
    )

    native.filegroup(
        name = name + "_expected",
        srcs = [name + "_impl"],
        output_group = "expected",
    )

    diff_test(
        name = name,
        file1 = name + "_expected",
        file2 = name + "_actual",
        diff_args = ["-u"],
    )
