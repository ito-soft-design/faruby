# frozen_string_literal: true

# 機種ごとに載せる機能
#
# **プログラム容量が足りない機種のための仕組みです。** MELSEC Q は
# クラスを入れた時点でプログラムメモリに収まらなくなりました
# (doc/melsec.md)。設定で機能を外せば、その機能のコードが生成物から
# 丸ごと落ちます。
#
# ## 切り口は「値の型」です。命令ではありません
#
# **命令を外しても減りません。** 実測で `OP_STRING` / `OP_STRCAT` を
# 外して 2.0%、段階 3 (配列・ハッシュ・文字列の命令) を丸ごと外しても
# 4.2% しか減りませんでした。
#
# かさばっているのは **共有している命令の中の型ごとの枝**です。Q の本体
# 6,122 行のうち:
#
#   OP_SEND     1,489 行 (24%)   組み込みメソッドの振り分け
#   OP_GETIDX     788 行 (13%)   デバイス参照・配列・ハッシュ・文字列・整数
#   OP_SETIDX     743 行 (12%)
#   OP_SETGV      615 行 (10%)   文字列・配列をデバイスへ書き出す
#   OP_GETGV      392 行 (6%)
#
# この 5 つで 66% です。どれも段階 1 の命令なので、段階を外しても残ります。
# **だから機能を外すときは、命令だけでなく組み込みメソッドと型の枝も
# 落とします。**
#
# ## 外した機能はコンパイル時に弾きます
#
# **実機で「未知のオペコード」にはしません。** 転送してから止まるのでは
# 気づくのが遅すぎます。使っていれば `rake transfer` の前に
# 「この機種では配列を使えません」で止めます。

require_relative "vm_constants"

module FaRuby
  # 外した機能を使っているときに発生
  class FeatureError < StandardError; end

  class Features
    include VmConstants

    # 機能の名前 => その機能だけが使う命令
    #
    # **ここに無い命令は共有です。** `OP_GETIDX` は配列にもハッシュにも
    # 文字列にもデバイス参照にも使うので、どの機能のものでもありません
    # (中の枝を落とします)。
    OPCODES = {
      arrays:  %i[OP_ARRAY OP_ARRAY2],
      hashes:  %i[OP_HASH],
      strings: %i[OP_STRING OP_STRCAT],
      classes: %i[OP_CLASS OP_GETCONST OP_EXEC],
    }.freeze

    # 機能の名前 => その機能だけが使う組み込みメソッド
    #
    # **`length` と `empty?` と `<<` は 3 つの型で共有します。** どれか 1 つ
    # でも残っていれば枝は要るので、全部外れたときだけ落とせます。
    METHODS = {
      arrays:  %i[push each length size empty? <<],
      hashes:  %i[key? keys values each length size empty?],
      strings: %i[length size empty? <<],
    }.freeze

    # 機能の名前 => Ruby での書き方 (エラーに出す)
    EXAMPLES = {
      arrays:  "配列 (`[1, 2]` / `a.push` / `a.each`)",
      hashes:  "ハッシュ (`{ a: 1 }` / `h.keys`)",
      strings: "文字列 (`\"abc\"` / 式展開)",
      classes: "クラス (`class Foo` / `Foo.new`)",
    }.freeze

    ALL = OPCODES.keys.freeze

    # 既定は全部載せます。**外すのは容量が足りない機種だけ**です
    DEFAULTS = ALL.to_h { |name| [name, true] }.freeze

    def self.all = new

    def initialize(settings = {})
      unknown = settings.keys.map(&:to_sym) - ALL
      unless unknown.empty?
        raise FeatureError,
              "知らない機能です: #{unknown.join(', ')} (#{ALL.join(', ')})"
      end

      @enabled = DEFAULTS.merge(settings.to_h { |k, v| [k.to_sym, !!v] })
    end

    def enabled?(name) = @enabled.fetch(name.to_sym)

    def arrays?  = enabled?(:arrays)
    def hashes?  = enabled?(:hashes)
    def strings? = enabled?(:strings)
    def classes? = enabled?(:classes)

    # 配列・ハッシュ・文字列のどれかが載っているか
    #
    # **プールを使うのはこの 3 つとオブジェクトです。** ひとつも無ければ
    # 「プールの空きを取る」コードも要りません (クラスは `new` で使います)。
    def heap? = arrays? || hashes? || strings? || classes?

    # 載せない機能
    def disabled = ALL.reject { |name| enabled?(name) }

    def all? = disabled.empty?

    # 落とす命令
    def removed_opcodes = disabled.flat_map { |name| OPCODES.fetch(name) }

    # 落とす組み込みメソッド
    #
    # **共有しているものは全員が外れたときだけ落とします。**
    def removed_methods
      shared = METHODS.values.flatten.tally
      disabled_names = disabled.flat_map { |name| METHODS.fetch(name, []) }.tally
      disabled_names.filter_map { |name, count| name if count == shared[name] }
    end

    # この命令を載せるか
    def opcode?(name) = !removed_opcodes.include?(name)

    # この組み込みメソッドを載せるか
    def method?(name) = !removed_methods.include?(name.to_sym)

    def to_h = @enabled.dup

    def to_s
      return "全機能" if all?

      disabled.map { |n| "#{n} なし" }.join(" / ")
    end
  end
end
