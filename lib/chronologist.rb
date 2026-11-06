require "json"
require "logger"
require_relative "chronologist/formatter"

module Chronologist
  VERSION = "0.1.0"

  Config = Struct.new(:format, :time_zone, :output, :enrichers, :fields, :loggers, :request_summary) do
    def initialize(*)
      super(:jsonl, nil, :auto, [], {}, [], false)
    end
  end

  class << self
    def config = (@config ||= Config.new)

    def configure = yield(config)

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
