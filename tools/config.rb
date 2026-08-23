# frozen_string_literal: true

# 設定ファイルの読み込み
#
#   faruby_default.yml  既定値の定義        (リポジトリに含む・編集しない)
#   faruby.yml          利用者の設定・差分  (git 管理外)
#
# faruby.yml に無い項目は faruby_default.yml の値が使われます。
# ネストしたキーは個別に解決するため、faruby.yml に memory.base だけを
# 書いても他のメモリ設定は既定値のまま残ります。

require "yaml"
require_relative "memory_layout"

module FaRuby
  # 設定が不正・不足している場合に発生
  class ConfigError < StandardError; end

  class Config
    PROJECT_ROOT     = File.expand_path("..", __dir__)
    DEFAULT_FILENAME = "faruby_default.yml"
    USER_FILENAME    = "faruby.yml"

    attr_reader :plc_protocol, :plc_host, :plc_port,
                :mrbc_path, :steps_per_cycle, :layout,
                :config_path, :default_path

    # config_path: 利用者設定のパス (nil なら自動探索)
    # user_config: false にすると既定値のみを読む (生成物の再現性検証用)
    def initialize(config_path = nil, user_config: true)
      @default_path = File.join(PROJECT_ROOT, DEFAULT_FILENAME)
      @config_path  = user_config ? (config_path || find_user_config) : nil

      merged = deep_merge(load_yaml(@default_path), load_yaml(@config_path))

      @plc_protocol    = merged.dig("plc", "protocol")
      @plc_host        = merged.dig("plc", "host")
      @plc_port        = merged.dig("plc", "port")
      @mrbc_path       = merged.dig("mrbc", "path") || find_mrbc
      @steps_per_cycle = merged.dig("vm", "steps_per_cycle")
      @layout          = MemoryLayout.from_config(merged["memory"] || {})
    end

    # 既定値のみの設定 (vm_core.kvs の再現性を保つために使う)
    def self.defaults
      new(user_config: false)
    end

    # PLC と通信する前に呼ぶ。既定値を持てない項目を検証する
    def validate_connection!
      if @plc_host.nil? || @plc_host.to_s.strip.empty?
        raise ConfigError,
              "PLC の IP アドレスが未設定です。#{USER_FILENAME} に plc.host を指定してください " \
              "(#{USER_FILENAME}.example を参照)"
      end
      self
    end

    private

    def load_yaml(path)
      return {} unless path && File.exist?(path)

      YAML.load_file(path) || {}
    end

    def find_user_config
      [Dir.pwd, PROJECT_ROOT]
        .map { |dir| File.join(dir, USER_FILENAME) }
        .find { |path| File.exist?(path) }
    end

    def find_mrbc
      candidates = [
        File.expand_path("mruby/build/host/bin/mrbc", PROJECT_ROOT),
        File.expand_path("mruby/build/host/bin/mrbc.exe", PROJECT_ROOT),
        "C:/mruby-build/mruby/build/host/bin/mrbc.exe",
        "mrbc",
        "mrbc.exe",
      ]
      candidates.find { |c| File.exist?(File.expand_path(c)) }&.then { |c| File.expand_path(c) } || "mrbc"
    end

    # ネストしたハッシュを再帰的にマージする
    # 値が nil の場合は「未設定」とみなし、既定値を残す
    def deep_merge(base, override)
      base.merge(override) do |_key, old_val, new_val|
        if old_val.is_a?(Hash) && new_val.is_a?(Hash)
          deep_merge(old_val, new_val)
        elsif new_val.nil?
          old_val
        else
          new_val
        end
      end
    end
  end
end
