module Chronologist
  module Enricher
    # OTel のトレースコンテキスト。datadog_ids: true で OTel トレースを Datadog 側でログと突き合わせる
    class OpenTelemetry
      def initialize(datadog_ids: false)
        @datadog_ids = datadog_ids
      end

      def call
        return {} unless defined?(::OpenTelemetry::Trace)

        ctx = ::OpenTelemetry::Trace.current_span.context
        return {} unless ctx.valid?

        out = { "trace_id" => ctx.hex_trace_id, "span_id" => ctx.hex_span_id,
                "trace_flags" => ctx.trace_flags.sampled? ? "01" : "00" }
        # Datadog は OTel trace id の下位64bitを10進にしたもので照合する
        if @datadog_ids
          out["dd"] = { "trace_id" => ctx.hex_trace_id[-16..].to_i(16).to_s, "span_id" => ctx.hex_span_id.to_i(16).to_s }
        end
        out
      end
    end
  end
end
