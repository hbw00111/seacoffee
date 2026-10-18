import Foundation
import IslandCore

final class ModelPricingTests {
    private func price(_ id: String, _ input: Decimal = 1, _ output: Decimal = 2, _ read: Decimal = 0, _ write: Decimal = 0) -> ModelPrice {
        ModelPrice(modelID: id, input: input, output: output, cacheRead: read, cacheWrite: write)
    }

    private func table(_ ids: [String]) -> [String: ModelPrice] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, price($0)) })
    }

    func candidates() {
        expectEqual(ModelPricing.candidates(for: "gpt-5.5"), ["gpt-5.5"])
        expectEqual(ModelPricing.candidates(for: "  GPT-5.5 "), ["gpt-5.5"])
        expectEqual(ModelPricing.candidates(for: "unknown"), [])
        expectEqual(ModelPricing.candidates(for: " None "), [])
        expectEqual(ModelPricing.candidates(for: ""), [])
        expectEqual(ModelPricing.candidates(for: "vendor/"), [])
        // vendor prefix, `:suffix`, `@`, `[1m]`
        expectEqual(ModelPricing.candidates(for: "moonshotai/kimi-k2-0905:exa"), ["kimi-k2-0905"])
        expectEqual(ModelPricing.candidates(for: "a/b/gpt-5"), ["gpt-5"])
        expectEqual(ModelPricing.candidates(for: "claude-opus-4-8[1m]"), ["claude-opus-4-8"])
        expectEqual(ModelPricing.candidates(for: "claude-opus-4-8[1m][1m]"), ["claude-opus-4-8"])
        expectEqual(ModelPricing.candidates(for: "gpt-5.2-codex@low"), ["gpt-5.2-codex-low", "gpt-5.2-codex"])
        // dated suffixes: ISO, YYYYMMDD, YYMMDD (valid and invalid)
        expectEqual(ModelPricing.candidates(for: "OpenAI/GPT-5.5-2026-05-14"), ["gpt-5.5-2026-05-14", "gpt-5.5"])
        expectEqual(ModelPricing.candidates(for: "claude-3-5-sonnet-20241022"), ["claude-3-5-sonnet-20241022", "claude-3-5-sonnet"])
        expectEqual(ModelPricing.candidates(for: "doubao-seed-2-1-pro-260628"), ["doubao-seed-2-1-pro-260628", "doubao-seed-2-1-pro"])
        expectEqual(ModelPricing.candidates(for: "foo-bar-123456"), ["foo-bar-123456"])
        expectEqual(ModelPricing.candidates(for: "widget-209900"), ["widget-209900"])
        expectEqual(ModelPricing.candidates(for: "gizmo-251200"), ["gizmo-251200"])
        expectEqual(ModelPricing.candidates(for: "模型-2026-05-14"), ["模型-2026-05-14", "模型"])
        expectEqual(ModelPricing.candidates(for: "abc🚀12345678"), ["abc🚀12345678"])
        // claude dots to dashes, and the claude- anywhere namespace strip
        expectEqual(ModelPricing.candidates(for: "anthropic/claude-haiku-4.5"), ["claude-haiku-4.5", "claude-haiku-4-5"])
        expectEqual(ModelPricing.candidates(for: "gpt-5.5.1"), ["gpt-5.5.1"])
        // bedrock/vertex: provider namespace, -vN and `:0`, in CC Switch's stack order
        expectEqual(ModelPricing.candidates(for: "global.anthropic.claude-haiku-4-5-20251001-v1:0"), [
            "global.anthropic.claude-haiku-4-5-20251001-v1", "global.anthropic.claude-haiku-4-5-20251001",
            "global.anthropic.claude-haiku-4-5", "claude-haiku-4-5", "claude-haiku-4-5-20251001", "claude-haiku-4-5-20251001-v1",
        ])
        expectEqual(ModelPricing.candidates(for: "openai.gpt-5"), ["openai.gpt-5", "gpt-5"])
        expectEqual(ModelPricing.candidates(for: "foo-v2"), ["foo-v2", "foo"])
        expectEqual(ModelPricing.candidates(for: "-v2"), ["-v2"])
        expectEqual(ModelPricing.candidates(for: "foo-vx"), ["foo-vx"])
        expectEqual(ModelPricing.candidates(for: "claude-opus-4-8@20260527"), ["claude-opus-4-8-20260527", "claude-opus-4-8"])
        // reasoning effort
        expectEqual(ModelPricing.candidates(for: "OpenAI/GPT-5.5@HIGH"), ["gpt-5.5-high", "gpt-5.5"])
        expectEqual(ModelPricing.candidates(for: "gpt-5-xhigh"), ["gpt-5-xhigh", "gpt-5"])
        expectEqual(ModelPricing.candidates(for: "-low"), ["-low"])
        // claude desktop wrapping a non-Anthropic model
        expectEqual(ModelPricing.candidates(for: "claude-gpt-5.5").first, "claude-gpt-5.5")
        expectEqual(Set(ModelPricing.candidates(for: "claude-gpt-5.5")), ["claude-gpt-5.5", "claude-gpt-5-5", "gpt-5.5", "gpt-5-5"])
        expectEqual(ModelPricing.candidates(for: "claude-opus-4-8"), ["claude-opus-4-8"])
        expectEqual(ModelPricing.candidates(for: "claude-novel-thing"), ["claude-novel-thing"])
        expectEqual(ModelPricing.candidates(for: "claude-nova-pro"), ["claude-nova-pro", "nova-pro"])
        // placeholders
        expectEqual(ModelPricing.isPlaceholder(""), true)
        expectEqual(ModelPricing.isPlaceholder("  "), true)
        expectEqual(ModelPricing.isPlaceholder("Unknown"), true)
        expectEqual(ModelPricing.isPlaceholder("NULL"), true)
        expectEqual(ModelPricing.isPlaceholder("none"), true)
        expectEqual(ModelPricing.isPlaceholder("gpt-5"), false)
        expectEqual(ModelPricing.pricingKey(pricingModel: "gpt-5", model: "x", requestModel: "y"), "gpt-5")
        expectEqual(ModelPricing.pricingKey(pricingModel: "unknown", model: "x", requestModel: "y"), "x")
        expectEqual(ModelPricing.pricingKey(pricingModel: nil, model: "x", requestModel: "y"), "x")
        expectEqual(ModelPricing.pricingKey(pricingModel: "", model: "", requestModel: "claude-sonnet-4-6"), "claude-sonnet-4-6")
        expectNil(ModelPricing.pricingKey(pricingModel: nil, model: "unknown", requestModel: "unknown"))
        expectNil(ModelPricing.pricingKey(pricingModel: nil, model: "", requestModel: nil))
        expectNil(ModelPricing.pricingKey(pricingModel: nil, model: "", requestModel: ""))
    }

    func lookup() {
        let t = table([
            "claude-sonnet-4-5-20250929", "claude-haiku-4.5", "claude-haiku-4-5-20251001", "claude-opus-4-8", "gpt-5.5", "gpt-5.5-high",
            "gpt-5.2-codex-low", "gpt-5.4", "gemini-3-pro-preview", "kimi-k2-0905", "doubao-seed-2-1-pro", "gpt-5-mini", "gpt-5-pro",
        ])
        func id(_ m: String) -> String? { ModelPricing.find(m, in: t)?.modelID }
        expectEqual(id("claude-sonnet-4-5-20250929"), "claude-sonnet-4-5-20250929")
        expectEqual(id("anthropic/claude-haiku-4.5"), "claude-haiku-4.5")
        expectEqual(id("moonshotai/kimi-k2-0905:exa"), "kimi-k2-0905")
        expectEqual(id("gpt-5.2-codex@low"), "gpt-5.2-codex-low")
        expectEqual(id("OpenAI/GPT-5.5@HIGH"), "gpt-5.5-high")
        expectEqual(id("OpenAI/GPT-5.5-2026-05-14"), "gpt-5.5")
        expectEqual(id("google/gemini-3-pro-preview-20260514"), "gemini-3-pro-preview")
        expectEqual(id("claude-haiku-4-5"), "claude-haiku-4-5-20251001")   // prefix pass
        expectEqual(id("anthropic/claude-opus-4.8"), "claude-opus-4-8")
        expectEqual(id("claude-gpt-5.5"), "gpt-5.5")
        expectEqual(id("global.anthropic.claude-haiku-4-5-20251001-v1:0"), "claude-haiku-4-5-20251001")
        expectEqual(id("global.anthropic.claude-opus-4-8-v1:0"), "claude-opus-4-8")
        expectEqual(id("claude-opus-4-8@20260527"), "claude-opus-4-8")
        expectEqual(id("gpt-5.4@low"), "gpt-5.4")
        expectEqual(id("doubao-seed-2-1-pro-260628"), "doubao-seed-2-1-pro")
        expectEqual(id("claude-opus-4-8[1m]"), "claude-opus-4-8")
        expectNil(ModelPricing.find("kimi-for-coding", in: t))
        expectNil(ModelPricing.find("unknown-model-123", in: t))
        expectNil(ModelPricing.find("unknown", in: t))
        expectNil(ModelPricing.find("", in: t))
        // "gpt-5" has no dash, so no prefix match onto gpt-5-mini/gpt-5-pro
        expectNil(ModelPricing.find("gpt-5", in: t))
        // `=` is case-sensitive: an upper-case key is not hit by the lowercased candidate (exact pass)
        expectNil(ModelPricing.find("gpt-5.4", in: ["GPT-5.4": price("GPT-5.4")]))

        // prefix-match rules per family
        func prefix(_ model: String, _ ids: [String]) -> String? { ModelPricing.find(model, in: table(ids))?.modelID }
        expectEqual(prefix("claude-opus-4", ["claude-opus-4-1"]), nil)          // 2 dashes
        expectEqual(prefix("claude-opus-4-1", ["claude-opus-4-1-20250805"]), "claude-opus-4-1-20250805")   // 3 dashes
        expectEqual(prefix("o3", ["o3-mini"]), nil)                              // 0 dashes
        expectEqual(prefix("o3-mini", ["o3-mini-high"]), "o3-mini-high")
        expectEqual(prefix("o4-mini", ["o4-mini-2025-04-16"]), "o4-mini-2025-04-16")
        expectEqual(prefix("gpt-5.1-codex", ["gpt-5.1-codex-max"]), "gpt-5.1-codex-max")
        expectEqual(prefix("gpt-5.1", ["gpt-5.1-codex"]), nil)                   // 1 dash
        expectEqual(prefix("gemini-3-pro", ["gemini-3-pro-preview"]), "gemini-3-pro-preview")
        expectEqual(prefix("glm-4-6", ["glm-4-6-x"]), "glm-4-6-x")
        expectEqual(prefix("llama-3-1", ["llama-3-1-70b"]), nil)                 // family not in list
        expectEqual(prefix("deepseek-v3-2", ["deepseek-v3-2-exp"]), "deepseek-v3-2-exp")
        // shortest model_id wins; ties go to the smallest id (SQLite's order is unspecified there)
        expectEqual(prefix("claude-haiku-4-5", ["claude-haiku-4-5-20251001", "claude-haiku-4-5-x"]), "claude-haiku-4-5-x")
        expectEqual(prefix("claude-haiku-4-5", ["claude-haiku-4-5-b", "claude-haiku-4-5-a"]), "claude-haiku-4-5-a")
        // LIKE: case-insensitive ASCII; `_` in the candidate matches any one character
        expectEqual(prefix("gpt-5.1-codex", ["GPT-5.1-CODEX-MAX"]), "GPT-5.1-CODEX-MAX")
        expectEqual(prefix("gemini-2_5-pro", ["gemini-2.5-pro-preview"]), "gemini-2.5-pro-preview")
        expectEqual(prefix("gemini-2_5-pro", ["gemini-2xx5-pro-preview"]), nil)
        expectEqual(prefix("gpt-5_1-codex", ["gpt-5-1-codex-mini"]), "gpt-5-1-codex-mini")
        // exact pass beats the prefix pass, and runs over every candidate first
        expectEqual(prefix("claude-haiku-4.5", ["claude-haiku-4-5-20251001", "claude-haiku-4-5"]), "claude-haiku-4-5")
    }

    func cost() {
        let p = price("m", 3, 15, Decimal(string: "0.3")!, Decimal(string: "3.75")!)
        func d(_ s: String) -> Decimal { Decimal(string: s)! }
        func run(_ app: String, _ sem: Int, _ mult: Decimal = 1, input: Decimal = 1000, read: Decimal = 200, write: Decimal = 100, price: ModelPrice? = nil) -> CostBreakdown {
            ModelPricing.cost(app: app, semantics: sem, input: input, output: 500, cacheRead: read, cacheWrite: write, price: price ?? p, multiplier: mult)
        }
        // claude: input is fresh, semantics ignored
        for sem in 0...2 {
            let c = run("claude", sem)
            expectEqual(c.input, d("0.003")); expectEqual(c.output, d("0.0075")); expectEqual(c.cacheRead, d("0.00006"))
            expectEqual(c.cacheWrite, d("0.000375")); expectEqual(c.total, d("0.010935"))
        }
        expectEqual(run("claude-desktop", 1).total, d("0.010935"))
        // codex: semantics 1 (total) deducts read and write; 0 (legacy) read only; 2 (fresh) none
        let total = run("codex", 1)
        expectEqual(total.input, d("0.0021")); expectEqual(total.total, d("0.010035"))
        let legacy = run("codex", 0)
        expectEqual(legacy.input, d("0.0024")); expectEqual(legacy.total, d("0.010335"))
        let fresh = run("codex", 2)
        expectEqual(fresh.input, d("0.003")); expectEqual(fresh.total, d("0.010935"))
        expectEqual(run("gemini", 1).input, d("0.0021"))
        // grokbuild does not double bill cached input
        let grok = ModelPricing.cost(app: "grokbuild", semantics: 1, input: 1000, output: 0, cacheRead: 600, cacheWrite: 0, price: price("g", 10, 0, 1, 0), multiplier: 1)
        expectEqual(grok.input, d("0.004")); expectEqual(grok.cacheRead, d("0.0006")); expectEqual(grok.total, d("0.0046"))
        // saturating subtraction
        expectEqual(run("codex", 1, input: 100, read: 80, write: 80).input, 0)
        expectEqual(run("codex", 0, input: 100, read: 150, write: 0).input, 0)
        // multiplier applies to the total only
        let m = ModelPricing.cost(app: "claude", semantics: 2, input: 1000, output: 0, cacheRead: 0, cacheWrite: 0, price: price("m", 3, 15), multiplier: d("1.5"))
        expectEqual(m.input, d("0.003")); expectEqual(m.total, d("0.0045"))
        // precision
        let tiny = ModelPricing.cost(app: "claude", semantics: 2, input: 1, output: 1, cacheRead: 1, cacheWrite: 1, price: price("t", d("0.075"), d("0.3"), d("0.01875"), d("0.075")), multiplier: 1)
        expectEqual(tiny.total, d("0.00000046875"))
    }
}
