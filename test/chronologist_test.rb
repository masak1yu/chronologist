require "minitest/autorun"
require "stringio"
# activesupport より先に読んでもタグ対応が効くことを確認するため先頭で require
require "chronologist"
require "chronologist/enricher/datadog"
require "chronologist/enricher/opentelemetry"

begin
  require "active_support"
  require "active_support/tagged_logging"
  require "active_support/logger"
  require "active_support/time"
rescue LoadError
end
require "msgpack"

class ChronologistTest < Minitest::Test
  T = Time.utc(2024, 1, 2, 3, 4, 5)
  ENV_KEYS = %w[DD_SERVICE DD_ENV DD_VERSION].freeze

  def setup
    Chronologist.instance_variable_set(:@config, nil)
    Chronologist.config.time_zone = "+09:00"
    @env = ENV_KEYS.to_h { |k| [k, ENV.delete(k)] }
  end

  def teardown
    @env.each { |k, v| ENV[k] = v }
    Object.send(:remove_const, :Datadog) if defined?(Datadog)
    Object.send(:remove_const, :OpenTelemetry) if defined?(OpenTelemetry)
  end

  def fmt(msg, sev = "INFO", prog = nil) = Chronologist.formatter.call(sev, T, prog, msg)
  def parse(msg, **kw) = JSON.parse(fmt(msg, **kw))

  def stub_datadog(trace_id: 123, span_id: 456)
    c = Struct.new(:trace_id, :span_id, :service, :env, :version).new(trace_id, span_id, "web", "prod", "1.0")
    Object.const_set(:Datadog, Module.new)
    Datadog.const_set(:Tracing, Module.new)
    Datadog::Tracing.define_singleton_method(:correlation) { c }
  end

  def stub_otel
    flags = Struct.new(:sampled?).new(true)
    ctx = Struct.new(:hex_trace_id, :hex_span_id, :trace_flags, :valid?)
            .new("0af7651916cd43dd8448eb211c80319c", "00f067aa0ba902b7", flags, true)
    Object.const_set(:OpenTelemetry, Module.new)
    OpenTelemetry.const_set(:Trace, Module.new)
    span = Struct.new(:context).new(ctx)
    OpenTelemetry::Trace.define_singleton_method(:current_span) { span }
  end

  def test_json_timestamp_has_configured_offset
    h = parse("hi")
    assert_equal "2024-01-02T12:04:05.000000+09:00", h["timestamp"]
    assert_equal "INFO", h["level"]
    assert_equal "hi", h["message"]
  end

  def test_default_time_zone_is_utc_even_if_rails_zone_or_tz_set
    Chronologist.config.time_zone = nil
    Time.zone_default = ActiveSupport::TimeZone["Tokyo"] if defined?(ActiveSupport::TimeZone)
    assert_equal "2024-01-02T03:04:05.000000Z", parse("x")["timestamp"]
  ensure
    Time.zone_default = nil if Time.respond_to?(:zone_default=)
  end

  def test_iana_time_zone
    skip "activesupport not available" unless defined?(ActiveSupport::TimeZone)
    Chronologist.config.time_zone = "Asia/Tokyo"
    assert_equal "2024-01-02T12:04:05.000000+09:00", parse("x")["timestamp"]
  end

  def test_hash_message_is_merged
    h = parse({ user: 1, "a" => 2 })
    assert_equal 1, h["user"]
    assert_equal 2, h["a"]
  end

  def test_exception_fills_error
    e = (raise "boom" rescue $!)
    h = parse(e)
    assert_equal "boom", h["message"]
    assert_equal "RuntimeError", h["error"]["kind"]
    assert_includes h["error"]["stack"], "chronologist_test.rb"
  end

  def test_multiline_message_stays_one_line
    out = fmt("a\nb")
    assert_equal 1, out.lines.size
    assert_equal "a\nb", JSON.parse(out)["message"]
  end

  def test_with_nests_and_restores_after_raise
    Chronologist.with(a: 1) do
      Chronologist.with(b: 2) { assert_equal({ "a" => 1, "b" => 2 }, parse("x").slice("a", "b")) }
      assert_nil parse("x")["b"]
    end
    assert_raises(RuntimeError) { Chronologist.with(a: 1) { raise "x" } }
    assert_nil parse("x")["a"]
  end

  def test_text_format_has_offset_and_flattened_keys
    stub_datadog
    dd!
    Chronologist.config.format = :text
    out = fmt("hi")
    assert_match(/\A2024-01-02T12:04:05\.000000\+09:00 INFO  hi /, out)
    assert_includes out, "dd.trace_id=123"
  end

  def test_msgpack_roundtrip
    Chronologist.config.format = :msgpack
    h = MessagePack.unpack(fmt("hi"))
    assert_equal "hi", h["message"]
  end

  def test_json_format_is_pretty_and_jsonl_is_one_line
    Chronologist.config.format = :json
    out = fmt("hi")
    assert_operator out.lines.size, :>, 1
    assert_equal "hi", JSON.parse(out)["message"]
    Chronologist.config.format = :jsonl
    assert_equal 1, fmt("a\nb").lines.size
  end

  def test_nil_message_writes_nothing
    assert_equal "", fmt(nil)
  end

  def test_callable_format
    Chronologist.config.format = ->(h) { "#{h["message"]}!" }
    assert_equal "hi!", fmt("hi")
  end

  def test_fields_callable_is_evaluated_per_line
    n = 0
    Chronologist.config.fields = { app: "web", n: -> { n += 1 } }
    assert_equal 1, parse("x")["n"]
    h = parse("x")
    assert_equal 2, h["n"]
    assert_equal "web", h["app"]
  end

  def dd! = Chronologist.config.enrichers = [Chronologist::Enricher::Datadog.new]

  def test_no_vendor_fields_by_default
    stub_datadog
    stub_otel
    ENV["DD_SERVICE"] = "api"
    h = parse("x")
    refute h.key?("dd")
    refute h.key?("trace_id")
  end

  def test_custom_enricher_and_failure_is_isolated
    Chronologist.config.enrichers = [-> { { "a" => 1 } }, -> { raise "x" }]
    assert_equal 1, parse("x")["a"]
  end

  def test_datadog_correlation
    stub_datadog
    dd!
    h = parse("x")
    assert_equal({ "trace_id" => "123", "span_id" => "456", "service" => "web", "env" => "prod", "version" => "1.0" }, h["dd"])
    assert_equal "web", h["service"]
    assert_equal "ruby", h["ddsource"]
    assert_equal "env:prod,version:1.0", h["ddtags"]
  end

  def test_datadog_without_active_trace_omits_ids
    stub_datadog(trace_id: 0, span_id: 0)
    dd!
    refute parse("x")["dd"].key?("trace_id")
  end

  def test_otel_fields
    stub_otel
    Chronologist.config.enrichers = [Chronologist::Enricher::OpenTelemetry.new]
    h = parse("x")
    assert_equal "00f067aa0ba902b7", h["span_id"]
    refute h.key?("dd")
  end

  def test_otel_converts_to_dd_ids_and_merges_with_datadog
    stub_otel
    ENV["DD_SERVICE"] = "api"
    Chronologist.config.enrichers = [Chronologist::Enricher::Datadog.new, Chronologist::Enricher::OpenTelemetry.new(datadog_ids: true)]
    h = parse("x")
    assert_equal "api", h["dd"]["service"]
    assert_equal "0af7651916cd43dd8448eb211c80319c", h["trace_id"]
    assert_equal "01", h["trace_flags"]
    assert_equal "8448eb211c80319c".to_i(16).to_s, h["dd"]["trace_id"]
    assert_equal "00f067aa0ba902b7".to_i(16).to_s, h["dd"]["span_id"]
  end

  def test_env_fallback_without_tracer
    ENV["DD_SERVICE"] = "api"
    ENV["DD_ENV"] = "stg"
    dd!
    h = parse("x")
    assert_equal "api", h["service"]
    assert_equal "env:stg", h["ddtags"]
    assert_equal({ "service" => "api", "env" => "stg" }, h["dd"])
  end

  def test_tagged_logging_tags_go_to_tags_field
    skip "activesupport not available" unless defined?(ActiveSupport::TaggedLogging)
    io = StringIO.new
    Chronologist.logger(io).tagged("req1") { |l| l.info("hello") }
    h = JSON.parse(io.string)
    assert_equal ["req1"], h["tags"]
    assert_equal "hello", h["message"]
  end
end
