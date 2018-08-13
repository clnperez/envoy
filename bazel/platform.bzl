def _impl(ctx):
    print("platform target is " + ctx.attr.platform_target)

platform_rule = repository_rule(
    implementation = _impl,
    attrs = {"platform_target": attr.string()}
)
