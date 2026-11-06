module Chronologist
  module Enricher
    # Datadog の APM-ログ相関と統合サービスタグ。ENV(DD_*) を各行に持たせ ECS/FireLens でも相関を保つ
    class Datadog
      def call
        c = ::Datadog::Tracing.correlation if defined?(::Datadog::Tracing) && ::Datadog::Tracing.respond_to?(:correlation)
        service = c&.service || ENV["DD_SERVICE"]
        env = c&.env || ENV["DD_ENV"]
        version = c&.version || ENV["DD_VERSION"]
        dd = { "service" => service, "env" => env, "version" => version }.compact
        if c && ![nil, 0, "0"].include?(c.trace_id)
          dd["trace_id"] = c.trace_id.to_s
          dd["span_id"] = c.span_id.to_s
        end
        return {} if dd.empty?

        out = { "dd" => dd, "ddsource" => "ruby" }
        out["service"] = service if service
        tags = [("env:#{env}" if env), ("version:#{version}" if version)].compact
        out["ddtags"] = tags.join(",") unless tags.empty?
        out
      end
    end
  end
end
