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
# **実行とメモリ配置は機種ごとに持ちます。** `faruby_default.yml` は機種ごとに
# 一式を持ち、`faruby.yml` には違うところだけを書きます。共通の位置に書いた
# 項目はどの機種にも効き、機種の下に書いた項目がそれを上回ります。
#
# ## 接続先
#
# **同じ機種の PLC が複数あるので、接続先は名前を付けて並べます。**
# どれを使うかは `current` で選びます。
#
#   connections:
#     current: line1
#     line1:
#       model: KV-5000
#       host: 10.0.1.201
#     line2:
#       model: KV-5000
#       host: 10.0.1.202
#     shiken:
#       model: KV-X500
#       host: 10.0.1.203
#
# **接続先が持つのは接続情報だけです** (機種・IP・ポート)。メモリ配置と実行
# 設定は機種のものです。**配置は生成物に焼き込まれる**ので、接続先ごとに
# 変えられるようにすると、生成物と中身が合わない組み合わせが作れてしまいます。
# 設備で配置が違う場合はフォルダを分けます (doc/architecture.md)。
#
# 重ねる順は次のとおりで、後のものが勝ちます。
#
#   1. faruby_default.yml の共通
#   2. faruby_default.yml の models.<機種>
#   3. faruby.yml の共通
#   4. faruby.yml の models.<機種>
#   5. connections.<current> (接続情報だけ)
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

    # どの接続先を使うかを指す見出し。接続先の名前には使えない
    CURRENT_KEY = "current"

    # 接続先が持てる項目。**接続情報だけ**で、配置や実行設定は機種のもの
    CONNECTION_KEYS = %w[model protocol host port].freeze

    attr_reader :connection, :connections, :model,
                :plc_protocol, :plc_host, :plc_port,
                :mrbc_path, :steps_per_cycle, :layout,
                :config_path, :default_path

    # config_path: 利用者設定のパス (nil なら自動探索)
    # user_config: false にすると既定値のみを読む (生成物の再現性検証用)
    # model:       機種 (nil なら接続先の機種、それも無ければ plc.model)
    # connection:  接続先の名前 (nil なら connections.current)
    def initialize(config_path = nil, user_config: true, model: nil, connection: nil)
      @default_path = File.join(PROJECT_ROOT, DEFAULT_FILENAME)
      @user_config  = user_config
      @config_path  = user_config ? (config_path || find_user_config) : nil

      defaults = load_yaml(@default_path)
      user     = load_yaml(@config_path)
      validate_models!(defaults, user)

      @connections = deep_merge(defaults["connections"].to_h, user["connections"].to_h)
      validate_connections!
      @connection = resolve_connection(connection)
      entry = @connections[@connection].to_h

      @model = model || entry["model"] ||
               user.dig("plc", "model") || defaults.dig("plc", "model")
      unless Dialect.models.include?(@model)
        raise ConfigError,
              "知らない機種です: #{@model.inspect} (使えるのは #{Dialect.models.join(', ')})"
      end

      merged = merge_for_model(defaults, user, entry)

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

      self.class.new(@config_path, user_config: @user_config,
                                   model: model, connection: @connection)
    end

    # 接続先の名前 (current を除く)
    def connection_names = @connections.keys - [CURRENT_KEY]

    # PLC と通信する前に呼ぶ。既定値を持てない項目を検証する
    def validate_connection!
      if @plc_host.nil? || @plc_host.to_s.strip.empty?
        raise ConfigError,
              "PLC の IP アドレスが未設定です。#{USER_FILENAME} に接続先 (connections) を " \
              "書くか、機種の plc.host を指定してください (#{USER_FILENAME}.example を参照)"
      end
      self
    end

    private

    # 共通・機種ごと・接続先を重ねる。順はファイル冒頭のとおり
    def merge_for_model(defaults, user, entry)
      [model_section(defaults), common(user), model_section(user), connection_layer(entry)]
        .reduce(common(defaults)) { |merged, layer| deep_merge(merged, layer) }
    end

    def common(data) = data.reject { |key, _| %w[models connections].include?(key) }

    def model_section(data) = data.dig("models", @model) || {}

    # 接続先が持つのは接続情報だけなので、plc の節に流し込む。
    # 空欄 (host: だけ書いて値が無い) は「未設定」として機種の値を残す
    def connection_layer(entry)
      plc = entry.slice("protocol", "host", "port").compact
      plc.empty? ? {} : { "plc" => plc }
    end

    # 名前を決める。current が無ければ 1 つだけのときに限りそれを使う
    def resolve_connection(name)
      names = connection_names
      chosen = name || @connections[CURRENT_KEY] || (names.first if names.size == 1)
      return nil if chosen.nil?

      unless names.include?(chosen)
        raise ConfigError,
              "知らない接続先です: #{chosen.inspect} " \
              "(#{names.empty? ? 'connections: がありません' : names.join(', ')})"
      end
      chosen
    end

    # 接続先に配置や実行設定を書いても効きません。黙って無視せず止めます
    def validate_connections!
      connection_names.each do |name|
        extra = @connections[name].to_h.keys - CONNECTION_KEYS
        next if extra.empty?

        raise ConfigError,
              "接続先 #{name} に書けない項目があります: #{extra.join(', ')} " \
              "(書けるのは #{CONNECTION_KEYS.join(', ')})。" \
              "配置と実行設定は機種のものです"
      end
    end

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
