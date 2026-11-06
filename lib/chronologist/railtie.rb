module Chronologist
  # lograge 相当: リクエスト毎のログを process_action 1 行に集約
  module RequestSummary
    module_function

    def install
      ActionController::LogSubscriber.detach_from(:action_controller) if defined?(ActionController::LogSubscriber)
      ActiveSupport.on_load(:action_view) { RequestSummary.silence_action_view }
      # call_app ごと差し替えると Rails のバージョン差分を抱えるので、メッセージだけ nil にする
      Rails::Rack::Logger.prepend(Module.new { def started_request_message(_) = nil })
      ActiveSupport::Notifications.subscribe("process_action.action_controller") do |event|
        Rails.logger.info(fields(event))
      end
    end

    def silence_action_view
      require "action_view/log_subscriber"
      ActionView::LogSubscriber.detach_from(:action_view)
      # "Rendering ..." の Start リスナーは detach_from の対象外なので個別に外す
      %w[render_template render_layout].each do |e|
        ActiveSupport::Notifications.notifier.listeners_for("#{e}.action_view").each do |l|
          next unless l.instance_variable_get(:@delegate).is_a?(ActionView::LogSubscriber::Start)

          ActiveSupport::Notifications.unsubscribe(l)
        end
      end
    end

    def fields(event)
      p = event.payload
      status = p[:status]
      if p[:exception] && defined?(ActionDispatch::ExceptionWrapper)
        status ||= ActionDispatch::ExceptionWrapper.status_code_for_exception(p[:exception].first)
      end
      { "method" => p[:method], "path" => p[:path], "format" => p[:format], "controller" => p[:controller],
        "action" => p[:action], "status" => status, "duration" => event.duration.round(2),
        "view" => p[:view_runtime]&.round(2), "db" => p[:db_runtime]&.round(2),
        "error" => (p[:exception] && { "kind" => p[:exception][0], "message" => p[:exception][1] }) }.compact
    end
  end

  class Railtie < ::Rails::Railtie
    # 設定は application.rb / environments/*.rb に書くこと。
    # config/initializers は initialize_logger より後に読まれ、反映が間に合わない
    config.chronologist = Chronologist.config

    initializer "chronologist.output", before: :initialize_logger do |app|
      if Chronologist.stdout? && app.config.logger.nil?
        app.config.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new($stdout))
      end
    end

    initializer "chronologist.formatter", after: :initialize_logger do
      Chronologist.apply(Rails.logger)
    end

    config.after_initialize do
      Chronologist.validate! # config/initializers で後から変えられた場合もここで検出
      RequestSummary.install if Chronologist.config.request_summary
      Chronologist.config.loggers.each do |l|
        logger = l.call
        Chronologist.apply(logger) if logger
      end
    end
  end
end
