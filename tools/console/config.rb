# frozen_string_literal: true

# コンフィグファイル読み込み
# faruby.yml から PLC 接続設定・mrbc パス等を読み込みます。

require "yaml"

module FaRuby
  module Console
    class Config
      DEFAULTS = {
        "plc" => {
          "protocol" => "keyence_kv",
          "host" => "192.168.0.10",
          "port" => 8501,
        },
        "mrbc" => {
          "path" => "mrbc",
        },
        "vm" => {
          "steps_per_cycle" => 50,
        },
      }.freeze

      CONFIG_FILENAME = "faruby.yml"

      attr_reader :plc_protocol, :plc_host, :plc_port,
                  :mrbc_path, :steps_per_cycle

      def initialize(config_path = nil)
        path = config_path || find_config_file
        data = path && File.exist?(path) ? YAML.load_file(path) : {}
        merged = deep_merge(DEFAULTS, data)

        @plc_protocol    = merged.dig("plc", "protocol")
        @plc_host        = merged.dig("plc", "host")
        @plc_port        = merged.dig("plc", "port")
        @mrbc_path       = merged.dig("mrbc", "path") || find_mrbc
        @steps_per_cycle = merged.dig("vm", "steps_per_cycle")
        @config_path     = path
      end

      def config_path
        @config_path
      end

      private

      def find_config_file
        # カレントディレクトリ
        local = File.join(Dir.pwd, CONFIG_FILENAME)
        return local if File.exist?(local)

        # プロジェクトルート (tools/console/ の2つ上)
        project_root = File.expand_path("../../..", __dir__)
        root = File.join(project_root, CONFIG_FILENAME)
        return root if File.exist?(root)

        nil
      end

      def find_mrbc
        candidates = [
          File.expand_path("../../../mruby/build/host/bin/mrbc", __dir__),
          File.expand_path("../../../mruby/build/host/bin/mrbc.exe", __dir__),
          "C:/mruby-build/mruby/build/host/bin/mrbc.exe",
          "mrbc",
          "mrbc.exe",
        ]

        candidates.each do |candidate|
          path = File.expand_path(candidate)
          return path if File.exist?(path)
        end

        "mrbc"
      end

      def deep_merge(base, override)
        base.merge(override) do |_key, old_val, new_val|
          if old_val.is_a?(Hash) && new_val.is_a?(Hash)
            deep_merge(old_val, new_val)
          else
            new_val
          end
        end
      end
    end
  end
end
