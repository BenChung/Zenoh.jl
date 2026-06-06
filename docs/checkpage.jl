# Build the full docs site into a private temp dir, so parallel runs never race
# on docs/build/. Loads the live module, so @docs/@ref targets resolve exactly as
# the real build resolves them. warnonly = true never throws; scan the output for
# "Warning:" lines. Pass a page path to print a reminder of which page to focus on.
#
#   julia --project=docs docs/checkpage.jl manual/queries.md
using Documenter
using Zenoh

focus = get(ARGS, 1, "")
out = mktempdir()
makedocs(
    sitename = "Zenoh.jl (check)",
    modules = [Zenoh],
    build = out,
    format = Documenter.HTML(prettyurls = false, size_threshold = nothing),
    warnonly = true,
)
println("\ncheckpage: full site built into ", out)
isempty(focus) || println("checkpage: focus page = ", focus, " (grep the log above for this path)")
