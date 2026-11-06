require "json"
require "logger"
require_relative "chronologist/formatter"

module Chronologist
  VERSION = "0.1.0"

  # 使わない環境では読み込まれないよう autoload。enrichers に :datadog 等のシンボルで指定できる
  module Enricher
    autoload :Datadog, "chronologist/enricher/datadog"
    autoload :OpenTelemetry, "chronologist/enricher/opentelemetry"
    NAMES = { datadog: :Datadog, opentelemetry: :OpenTelemetry }.freeze

    def self.[](name)
      (@cache ||= {})[name] ||= const_get(NAMES.fetch(name) { raise ArgumentError, "unknown enricher: #{name}" }).new
    end
  end

  Config = Struct.new(:format, :time_zone, :output, :enrichers, :fields, :loggers, :request_summary) do
    def initialize(*)
      super(:jsonl, nil, :auto, [], {}, [], false)
    end
  end

  class << self
    def config = (@config ||= Config.new)

    def configure = yield(config)

    FORMATS = %i[jsonl json text msgpack].freeze
    OUTPUTS = %i[auto stdout default].freeze

    # ログ毎ではなく起動時に落とすための検証。誤設定は ArgumentError
    def validate!(c = config)
      err = ->(msg) { raise ArgumentError, "chronologist: #{msg}" }
      err.("format は #{FORMATS.inspect} か call 可能なもの: #{c.format.inspect}") unless FORMATS.include?(c.format) || c.format.respond_to?(:call)
      if c.format == :msgpack
        begin
          require "msgpack"
        rescue LoadError
          err.("format :msgpack には msgpack gem が必要")
        end
      end
      err.("output は #{OUTPUTS.inspect}: #{c.output.inspect}") unless OUTPUTS.include?(c.output)
      tz = c.time_zone
      unless tz.nil? || tz.to_s.match?(/\A[+-]\d\d:\d\d\z/)
        err.("time_zone #{tz.inspect} の解決には activesupport が必要") unless defined?(ActiveSupport::TimeZone)
        err.("不明な time_zone: #{tz.inspect}") unless ActiveSupport::TimeZone[tz]
      end
      c.enrichers.each do |e|
        next if e.respond_to?(:call)
        err.("不明な enricher: #{e.inspect}（#{Enricher::NAMES.keys.inspect} か call 可能なもの）") unless Enricher::NAMES.key?(e)
      end
      err.("fields は Hash: #{c.fields.inspect}") unless c.fields.is_a?(Hash)
      c.loggers.each { |l| err.("loggers の要素は call 可能なもの: #{l.inspect}") unless l.respond_to?(:call) }
      true
    end

    # Thread.current[] は fiber-local。スレッド共有の変数は使わない
    def with(**fields)
      prev = Thread.current[:chronologist_context]
      Thread.current[:chronologist_context] = (prev || {}).merge(fields.transform_keys(&:to_s))
      yield
    ensure
      Thread.current[:chronologist_context] = prev
    end

    def formatter
      # 読込時に include しないのは chronologist が activesupport より先に require されうるため。
      # include なら class 自身の call が優先され、タグはメッセージに前置されず tags に入る
      if defined?(ActiveSupport::TaggedLogging::Formatter) && !(Formatter < ActiveSupport::TaggedLogging::Formatter)
        Formatter.include(ActiveSupport::TaggedLogging::Formatter)
      end
      validate!
      Formatter.new
    end

    def logger(io = $stdout)
      l = apply(::Logger.new(io))
      return l unless defined?(ActiveSupport::TaggedLogging)

      apply(ActiveSupport::TaggedLogging.new(l))
    end

    def apply(logger)
      if logger.respond_to?(:broadcasts)
        logger.broadcasts.each { |l| apply(l) }
      else
        # formatter を共有すると TaggedLogging のタグが二重に積まれる
        logger.formatter = formatter
      end
      logger
    end

    def on_ecs?
      !!(ENV["ECS_CONTAINER_METADATA_URI_V4"] || ENV["ECS_CONTAINER_METADATA_URI"])
    end

    def stdout?
      case config.output
      when :stdout then true
      when :auto then on_ecs? || !ENV["RAILS_LOG_TO_STDOUT"].to_s.empty?
      else false
      end
    end
  end
end

require_relative "chronologist/railtie" if defined?(Rails::Railtie)
