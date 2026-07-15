"""Fixture rules for expander tests."""

def _write_file_impl(ctx):
    ctx.actions.write(ctx.outputs.out, ctx.attr.content)
    return [DefaultInfo(files = depset([ctx.outputs.out]))]

write_file = rule(
    implementation = _write_file_impl,
    attrs = {
        "out": attr.output(),
        "content": attr.string(),
    },
)

def _multi_output_binary_impl(ctx):
    exe = ctx.actions.declare_file(ctx.label.name + ".exe")
    ctx.actions.write(exe, "#!/bin/sh\n", is_executable = True)
    dbg = ctx.actions.declare_file(ctx.label.name + ".dbg")
    ctx.actions.write(dbg, "")
    return [DefaultInfo(
        executable = exe,
        files = depset([exe, dbg]),
    )]

# An executable target whose default outputs are not a single file: location
# expansion prefers the executable for such targets.
multi_output_binary = rule(
    implementation = _multi_output_binary_impl,
    executable = True,
)

def _tree_impl(ctx):
    dir = ctx.actions.declare_directory(ctx.label.name + ".dir")
    ctx.actions.run_shell(
        outputs = [dir],
        command = 'mkdir -p "$1" && echo one > "$1/one.txt" && echo two > "$1/two.txt"',
        arguments = [dir.path],
    )
    return [DefaultInfo(files = depset([dir]))]

tree = rule(implementation = _tree_impl)

def _write_lines_impl(ctx):
    # Written via an Args object so that the file format is byte-for-byte
    # identical to that of the expander outputs.
    args = ctx.actions.args().set_param_file_format("multiline")
    args.add_all(ctx.attr.lines)
    out = ctx.actions.declare_file(ctx.label.name + ".golden")
    ctx.actions.write(output = out, content = args)
    return [DefaultInfo(files = depset([out]))]

write_lines = rule(
    implementation = _write_lines_impl,
    attrs = {
        "lines": attr.string_list(),
    },
)
