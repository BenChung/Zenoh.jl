using Documenter
using Zenoh

makedocs(
    sitename = "Zenoh.jl",
    modules = [Zenoh],
    authors = "Benjamin Chung and contributors",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://BenChung.github.io/Zenoh.jl",
        edit_link = "master",
    ),
    pages = [
        "Home" => "index.md",
        "Getting Started" => "getting-started.md",
        "Manual" => [
            "Key Expressions" => "manual/key-expressions.md",
            "Sessions & Configuration" => "manual/sessions-and-configuration.md",
            "Publish & Subscribe" => "manual/publish-subscribe.md",
            "Samples" => "manual/samples.md",
            "Payloads & Serialization" => "manual/payloads-and-serialization.md",
            "Encoding" => "manual/encoding.md",
            "Queries" => "manual/queries.md",
            "Quality of Service" => "manual/quality-of-service.md",
            "Liveliness" => "manual/liveliness.md",
            "Matching" => "manual/matching.md",
            "Scouting" => "manual/scouting.md",
            "Advanced Pub/Sub" => "manual/advanced-pubsub.md",
            "Shared Memory" => "manual/shared-memory.md",
            "Logging" => "manual/logging.md",
        ],
        "API Reference" => "reference.md",
    ],
    checkdocs = :exports,
)

deploydocs(
    repo = "github.com/BenChung/Zenoh.jl.git",
    devbranch = "master",
    push_preview = true,
)
