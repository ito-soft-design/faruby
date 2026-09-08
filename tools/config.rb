# frozen_string_literal: true

# 設定ファイルの読み込み
#
#   faruby_default.yml  既定値の定義        (リポジトリに含む・編集しない)
#   faruby.yml          利用者の設定・差分  (git 管理外)
#
# faruby.yml に無い項目は faruby_default.yml の値が使われます。
# ネストしたキーは個別に解決するため、faruby.yml に memory.base だけを
# 書いても他のメモリ設定は既定値のまま残ります。
#
# ## 機種ごとの設定
#
# 共通の設定を `models:` の下で機種ごとに上書きします。**書いた項目だけが
# 差し替わります。**
#
#   plc:
#     model: KV-5000        いま相手にしている機種
#     host: 10.0.1.201      どの機種でもこれを使う
#   models:
#     KV-X500:
#       plc:
#         host: 10.0.1.202  KV-X500 のときだけ差し替わる
#
# 重ねる順は次のとおりで、後のものが勝ちます。
#
#   1. faruby_default.yml の共通
#   2. faruby_default.yml の models.<機種>
#   3. faruby.yml の共通
#   4. faruby.yml の models.<機種>
#
# **利用者が書いた共通の設定は、既定の機種別より優先します。** 既定は
# こちらの見込みでしかなく、利用者が書いたものはその設備の事実だからです。

require "yaml"
require_relative "dialect"
require_relative "memory_layout"

module FaRuby
  # 設定が不正・不足している場合に発生
  class ConfigError < StandardError; end

  class Config
    PROJECT_ROOT     = File.expand_path("..", __dir__)
    DEFAULT_FILENAME = "faruby_default.yml"
    USER_FILENAME    = "faruby.yml"

    attr_reader :model, :plc_protocol, :plc_host, :plc_port,
                :mrbc_path, :steps_per_cycle, :layout,
                :config_path, :default_path

    # config_path: 利用者設定のパス (nil なら自動探索)
    # user_config: false にすると既定値のみを読む (生成物の再現性検証用)
    # model:       機種 (nil なら設定の plc.model)
    def initialize(config_path = nil, user_config: true, model: nil)
      @default_path = File.join(PROJECT_ROOT, DEFAULT_FILENAME)
      @user_config  = user_config
      @config_path  = user_config ? (config_path || find_user_config) : nil

      defaults = load_yaml(@default_path)
      user     = load_yaml(@config_path)
      validate_models!(defaults, user)

      @model = model || user.dig("plc", "model") || defaults.dig("plc", "model")
      unless Dialect.models.include?(@model)
        raise ConfigError,
              "知らない機種です: #{@model.inspect} (使えるのは #{Dialect.models.join(', ')})"
      end

      merged = merge_for_model(defaults, user)

      @plc_protocol    = merged.dig("plc", "protocol")
      @plc_host        = merged.dig("plc", "host")
      @plc_port        = merged.dig("plc", "port")
      @mrbc_path       = merged.dig("mrbc", "path") || find_mrbc
      @steps_per_cycle = merged.dig("vm", "steps_per_cycle")
      @layout          = MemoryLayout.from_config(merged["memory"] || {})
    end

    # 既定値のみの設定 (生成スクリプトの再現性を保つために使う)
    def self.defaults
      new(user_config: false)
    end

    # 同じ設定ファイルを別の機種で読み直す
    #
    # **生成 (`rake vm_core`) は全機種ぶん出します。** 機種ごとにメモリ配置が
    # 違えば、それぞれの生成物にその配置が焼き込まれます。
    def for_model(model)
      return self if model == @model

      self.class.new(@config_path, user_config: @user_config, model: model)
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

    # 共通と機種ごとを重ねる。順はファイル冒頭のとおり
    def merge_for_model(defaults, user)
      [model_section(defaults), common(user), model_section(user)]
        .reduce(common(defaults)) { |merged, layer| deep_merge(merged, layer) }
    end

    def common(data) = data.reject { |key, _| key == "models" }

    def model_section(data) = data.dig("models", @model) || {}

    # 綴じ間違いをここで止める。知らない見出しは黙って無視されると気づけない
    def validate_models!(defaults, user)
      names = (defaults["models"].to_h.keys + user["models"].to_h.keys).uniq
      unknown = names - Dialect.models
      return if unknown.empty?

      raise ConfigError,
            "知らない機種が models: にあります: #{unknown.join(', ')} " \
            "(使えるのは #{Dialect.models.join(', ')})"
    end

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
