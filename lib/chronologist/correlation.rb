module Chronologist
  module Correlation
    module_function

    def fields
      return {} unless Chronologist.config.correlation

      out = datadog
      otel(out)
      out
    rescue StandardError
      {} # 相関取得の失敗でログ自体を落とさない
    end

    def datadog
      c = Datadog::Tracing.correlation if defined?(Datadog::Tracing) && Datadog::Tracing.respond_to?(:correlation)
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

    def otel(out)
      return unless defined?(OpenTelemetry::Trace)

      ctx = OpenTelemetry::Trace.current_span.context
      return unless ctx.valid?

      out["trace_id"] = ctx.hex_trace_id
      out["span_id"] = ctx.hex_span_id
      out["trace_flags"] = ctx.trace_flags.sampled? ? "01" : "00"
      dd = (out["dd"] ||= {})
      return if dd["trace_id"]

      # Datadog は OTel の下位64bitを10進にしたものでログと突き合わせる
      dd["trace_id"] = ctx.hex_trace_id[-16..].to_i(16).to_s
      dd["span_id"] = ctx.hex_span_id.to_i(16).to_s
    end
  end
end
