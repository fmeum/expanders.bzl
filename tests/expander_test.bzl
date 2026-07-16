"""Test rules diffing expanders.bzl against native expansion.

expander_test(name, expand, ...) asserts that, for every string in expand,
the Args-based expansion produces exactly the same bytes as

    ctx.expand_make_variables("expand", ctx.expand_location(input, targets), extra_vars)

both without path mapping (outputs must be identical to the native strings)
and with path mapping enabled (outputs must be identical to the native
strings with the configuration segment of the output directory mapped away).

The comparison relies on ctx.actions.write emitting an Args object via a
ParamFileWriteAction, which honors --experimental_output_paths=strip if the
action declares support for path mapping via its execution requirements.
"""

load("@bazel_lib//lib:diff_test.bzl", "diff_test")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@expanders.bzl", "expanders")
load("//:support.bzl", "write_lines")

# Bazel's path mapper replaces the configuration segment of output paths with
# the constant "cfg".
_MAPPED_BIN_DIR = "bazel-out/cfg/bin"

def _do_expand_impl(ctx):
    for out in ctx.outputs.outs:
        ctx.actions.write(out, "")

    targets = ctx.attr.srcs + ctx.attr.data

    # An extra variable whose value embeds the output directory path, like
    # toolchain-provided variables pointing at generated tools do.
    extra_vars = dict(ctx.attr.extra_vars)
    extra_vars["TEST_BINDIR_TOOL"] = ctx.bin_dir.path + "/injected/tool"

    expander = expanders.make(ctx, targets = targets, extra_vars = extra_vars)

    if ctx.attr.with_expected:
        expanded = [
            ctx.expand_make_variables("expand", ctx.expand_location(input, targets), extra_vars)
            for input in ctx.attr.expand
        ]
    else:
        expanded = []

    groups = {}
    for mapped in (False, True):
        suffix = "_mapped" if mapped else ""

        args = ctx.actions.args().set_param_file_format("multiline")
        for input in ctx.attr.expand:
            expander.expand(args, input)
        actual = ctx.actions.declare_file("%s.actual%s" % (ctx.label.name, suffix))
        write_kwargs = {"execution_requirements": {"supports-path-mapping": "1"}} if mapped else {}
        ctx.actions.write(output = actual, content = args, **write_kwargs)
        groups["actual" + suffix] = depset([actual])

        if ctx.attr.with_expected:
            lines = [line.replace(ctx.bin_dir.path, _MAPPED_BIN_DIR) for line in expanded] if mapped else expanded
            expected_args = ctx.actions.args().set_param_file_format("multiline")
            expected_args.add_all(lines)
            expected = ctx.actions.declare_file("%s.expected%s" % (ctx.label.name, suffix))
            ctx.actions.write(output = expected, content = expected_args)
            groups["expected" + suffix] = depset([expected])

    return [OutputGroupInfo(**groups)]

_do_expand = rule(
    implementation = _do_expand_impl,
    attrs = {
        "expand": attr.string_list(),
        "srcs": attr.label_list(allow_files = True),
        "data": attr.label_list(allow_files = True),
        # Only implicitly addressable in location expressions, never passed
        # as explicit targets by the test rule.
        "tools": attr.label_list(allow_files = True),
        "outs": attr.output_list(),
        "extra_vars": attr.string_dict(),
        "with_expected": attr.bool(default = True),
    },
)

def _output_group(name, impl, group, **kwargs):
    native.filegroup(
        name = name,
        srcs = [impl],
        output_group = group,
        **kwargs
    )

def expander_test(name, expand, srcs = [], data = [], tools = [], outs = [], extra_vars = {}, **kwargs):
    """Diffs expanders.bzl output against native expansion, with and without path mapping."""
    _do_expand(
        name = name + "_impl",
        expand = expand,
        srcs = srcs,
        data = data,
        tools = tools,
        outs = outs,
        extra_vars = extra_vars,
        **kwargs
    )

    for group in ("actual", "actual_mapped", "expected", "expected_mapped"):
        _output_group("%s_%s" % (name, group), name + "_impl", group, **kwargs)

    diff_test(
        name = name,
        file1 = name + "_expected",
        file2 = name + "_actual",
        diff_args = ["-u"],
        **kwargs
    )

    diff_test(
        name = name + "_mapped",
        file1 = name + "_expected_mapped",
        file2 = name + "_actual_mapped",
        diff_args = ["-u"],
        **kwargs
    )

def _failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.msg)
    return analysistest.end(env)

_failure_test = analysistest.make(
    _failure_test_impl,
    expect_failure = True,
    attrs = {"msg": attr.string()},
)

def expander_failure_test(name, expand, msg, srcs = [], data = [], extra_vars = {}, **kwargs):
    """Asserts that expanding the given string fails with a native-style error message."""
    _do_expand(
        name = name + "_impl",
        expand = [expand],
        srcs = srcs,
        data = data,
        extra_vars = extra_vars,
        with_expected = False,
        tags = ["manual"],
        **kwargs
    )

    _failure_test(
        name = name,
        msg = msg,
        target_under_test = name + "_impl",
        **kwargs
    )

def expander_golden_test(name, expand, golden, srcs = [], data = [], extra_vars = {}, **kwargs):
    """Diffs expanders.bzl output against explicitly given lines.

    Used for the few inputs on which expanders.bzl intentionally diverges
    from the two-pass native expansion (e.g. "$$(location ...)", which
    expanders.bzl treats as an escape just like genrules do).
    """
    _do_expand(
        name = name + "_impl",
        expand = expand,
        srcs = srcs,
        data = data,
        extra_vars = extra_vars,
        with_expected = False,
        **kwargs
    )

    _output_group(name + "_actual", name + "_impl", "actual", **kwargs)

    write_lines(
        name = name + "_golden",
        lines = golden,
        **kwargs
    )

    diff_test(
        name = name,
        file1 = name + "_golden",
        file2 = name + "_actual",
        diff_args = ["-u"],
        **kwargs
    )
