module Chronologist
  class Formatter < ::Logger::Formatter
    def call(severity, time, progname, msg)
      return "" if msg.nil? # request_summary で抑止した "Started ..." 行。空文字は何も書かれない
      cfg = Chronologist.config
      h = { "timestamp" => stamp(time, cfg.time_zone), "level" => severity }
      h["progname"] = progname.to_s if progname
      tags = current_tags if respond_to?(:current_tags)
      h["tags"] = tags.dup if tags && !tags.empty?
      h.merge!(body(msg))
      h.merge!(Thread.current[:chronologist_context] || {})
      h.merge!(cfg.fields.to_h { |k, v| [k.to_s, v.respond_to?(:call) ? v.call : v] })
      # dd などのネストは enricher 間で 1 段だけマージ（後勝ち）
      cfg.enrichers.each { |e| h.merge!(enrich(e)) { |_, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? a.merge(b) : b } }
      render(h, cfg.format)
    end

    private

    def enrich(e)
      e.call || {}
    rescue StandardError
      {} # 付加情報の失敗でログ自体を落とさない
    end

    def stamp(time, zone)
      t =
        # 未指定は UTC 固定。Rails の config.time_zone やサーバの TZ に引きずられないようにする
        if zone.nil?
          time.getutc
        elsif zone.to_s.match?(/\A[+-]\d\d:\d\d\z/)
          time.getlocal(zone)
        else
          (ActiveSupport::TimeZone[zone] || raise(ArgumentError, "unknown time_zone: #{zone}")).at(time)
        end
      t.iso8601(6)
    end

    def body(msg)
      case msg
      when String then { "message" => msg }
      when Hash then msg.transform_keys(&:to_s)
      when Exception
        { "message" => msg.message,
          "error" => { "kind" => msg.class.name, "message" => msg.message, "stack" => msg.backtrace&.join("\n") }.compact }
      else { "message" => msg.inspect }
      end
    end

    def render(h, format)
      case format
      when :jsonl then JSON.generate(h) << "\n"
      when :json then JSON.pretty_generate(h) << "\n"
      when :msgpack
        begin
          require "msgpack"
        rescue LoadError
          raise LoadError, "format :msgpack には msgpack gem が必要です"
        end
        MessagePack.pack(h)
      when :text then text(h)
      else format.call(h)
      end
    end

    def text(h)
      h = h.dup
      head = "#{h.delete("timestamp")} #{h.delete("level").to_s.ljust(5)} "
      tags = h.delete("tags")
      head << "[#{tags.join("] [")}] " if tags
      head << h.delete("message").to_s
      stack = h["error"]&.delete("stack")
      line = flatten(h).map { |k, v| " #{k}=#{v}" }.join
      "#{head}#{line}\n#{"#{stack}\n" if stack}"
    end

    def flatten(h, prefix = nil)
      h.each_with_object({}) do |(k, v), out|
        key = [prefix, k].compact.join(".")
        v.is_a?(Hash) ? out.merge!(flatten(v, key)) : out[key] = v
      end
    end
  end
end
