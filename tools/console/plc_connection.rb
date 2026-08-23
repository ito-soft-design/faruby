# frozen_string_literal: true

# PLC 接続ファクトリ
# コンフィグの protocol 設定に基づき、適切なアダプターを生成します。

require_relative "plc_adapters/keyence_kv"

module FaRuby
  module Console
    class PlcConnection
      ADAPTERS = {
        "keyence_kv" => ->(cfg) {
          PlcAdapters::KeyenceKv.new(host: cfg.plc_host, port: cfg.plc_port)
        },
        # 将来追加:
        # "mitsubishi_mc" => ->(cfg) { PlcAdapters::MitsubishiMc.new(...) },
        # "omron_fins"    => ->(cfg) { PlcAdapters::OmronFins.new(...) },
      }.freeze

      def self.create(config)
        factory = ADAPTERS[config.plc_protocol]
        raise "Unknown PLC protocol: #{config.plc_protocol}" unless factory

        factory.call(config)
      end
    end
  end
end
