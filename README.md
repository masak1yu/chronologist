# chronologist

Rails ログの書式・タイムゾーン・トレース相関を一箇所で統一する gem。ランタイム依存なし。

## 使い方

`config/application.rb` か `config/environments/*.rb` に書く(initializers では遅い)。

```ruby
config.chronologist.format = :jsonl           # :jsonl(1行1JSON) | :json(整形) | :text | :msgpack | ->(hash) { String }
config.chronologist.request_summary = true    # lograge 相当: リクエストログを 1 行に集約
config.chronologist.time_zone = "Asia/Tokyo"  # IANA名 or "+09:00"。nil なら Time.zone_default / ローカル
config.chronologist.output = :auto            # :auto | :stdout | :default
config.chronologist.fields = { app: "web", host: -> { Socket.gethostname } }
config.chronologist.loggers = [-> { Sidekiq.logger }]
```

- `request_summary`: Started/Processing/Rendered/Completed を消し、`method path format controller action status duration view db error` の 1 行にする
- `output :auto`: ECS 上または `RAILS_LOG_TO_STDOUT` があれば stdout に出力
- `Chronologist.with(user_id: 1) { ... }`: ブロック内の全行にフィールド追加
- Rails 外: `Chronologist.logger` / `Chronologist.apply(logger)`
- Datadog: `dd.trace_id` 等を自動付与。`DD_SERVICE` / `DD_ENV` / `DD_VERSION` から `service` `ddsource` `ddtags` も付与
- OpenTelemetry: `trace_id` `span_id` `trace_flags` と、Datadog 連携用の `dd.trace_id` を付与
- `correlation = false` で相関を無効化

## テスト

`bundle exec rake`
