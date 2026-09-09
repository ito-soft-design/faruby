# frozen_string_literal: true

require_relative "vm_constants"

module FaRuby
  # Ruby プログラムから触れるラダーのデバイス
  #
  # **種別はメーカーごとに違います。** キーエンスの `EM` / `MR` に当たるものは
  # 三菱にありません。名前だけでなく、番号の数え方も違います (10 進・16 進)。
  #
  # 番号 (`type`) は faRuby の中だけのもので、バイトコードと生成コードの
  # 両方がこの表から出ます。**どちらも同じ機種向けに同時に作る**ので、
  # 機種ごとに番号が違っても食い違いません。
  #
  # 並び順に意味があります。**ワードデバイスが先、ビットデバイスが後**で、
  # 生成コードは `種別 > 最後のワード種別` の 1 比較でどちらかを見分けます。
  class DeviceSet
    # 1 種別
    #
    #   type       faRuby の中での番号
    #   name       正式名 (`DM`、`D`)
    #   kind       :word か :bit
    #   writable   書けるか。タイマ・カウンタの接点は読み取り専用
    #   numbering  ホストがアドレスを番号に直すときの数え方
    #   aliases    ラダーで受け付ける略記 (`$D100` を `DM100` と読む)
    #   supported  false なら生成コードに出しません。**番号は空けたまま**
    #              残します。詰めると既存のバイトコードが別のデバイスを指します
    #   float      実数として読み書きできるか。タイマ・カウンタは幅を付けると
    #              現在値を返すデバイスなので、実数の出番がありません
    Device = Struct.new(:type, :name, :kind, :writable, :numbering, :aliases,
                        :supported, :float, keyword_init: true) do
      def word? = kind == :word
      def bit?  = kind == :bit
      def supported? = supported != false
      def float? = float != false
    end

    attr_reader :devices

    def initialize(devices)
      @devices = devices.freeze
      validate!
    end

    # **使える種別だけ。** 番号を引くときは devices を見ます
    def word_devices = @word_devices ||= devices.select { |d| d.word? && d.supported? }
    def bit_devices  = @bit_devices  ||= devices.select { |d| d.bit? && d.supported? }

    # ワードとビットの境目。生成コードはここで 1 回だけ比べます
    def last_word_type = word_devices.last.type

    # 文字列を書けるデバイス
    #
    # ビットデバイスに文字列を書く意味は無く、書けたとしてもビット単位の
    # 読み書きになって表示器から読めません。
    def string_types = word_devices.map(&:type)

    def find(type) = devices.find { |d| d.type == type }

    # 名前 (略記も可) から種別を引く
    def type_for(name)
      key = name.to_s.upcase
      found = devices.find { |d| d.name == key || d.aliases.include?(key) }
      found&.type
    end

    # 略記を正式名に直す。**plc_access は略記を知りません**
    def normalize(name)
      key = name.to_s.upcase
      devices.find { |d| d.name == key || d.aliases.include?(key) }&.name || key
    end

    # 実数を扱えないデバイス
    def no_float_types = devices.reject(&:float?).map(&:type)

    # この種別を外した表。機種が指せないデバイスを落とします
    #
    # **番号は空けたまま残します。** 詰めると既存のバイトコードが別の
    # デバイスを指してしまいます。
    def without(*types)
      return self if types.empty?

      self.class.new(devices.map { |d| types.include?(d.type) ? d.dup.tap { |x| x.supported = false } : d })
    end

    private

    # **並び順と番号がずれていると、生成コードの範囲判定が静かに壊れます。**
    # ワードが先・ビットが後で、番号が 0 から連番であることを確かめます。
    def validate!
      kinds = devices.map(&:kind)
      raise ArgumentError, "ワードデバイスを先に並べてください" if kinds != kinds.sort_by { |k| k == :word ? 0 : 1 }

      expected = (0...devices.size).to_a
      return if devices.map(&:type) == expected

      raise ArgumentError, "種別の番号は 0 からの連番です: #{devices.map(&:type).inspect}"
    end

    # --- 機種ごとの表 ---

    def self.keyence
      @keyence ||= new([
        Device.new(type: 0, name: "EM", kind: :word, writable: true, numbering: :dec, aliases: %w[E]),
        Device.new(type: 1, name: "DM", kind: :word, writable: true, numbering: :dec, aliases: %w[D]),
        Device.new(type: 2, name: "ZF", kind: :word, writable: true, numbering: :dec, aliases: []),
        Device.new(type: 3, name: "R",  kind: :bit,  writable: true, numbering: :hexdec, aliases: []),
        Device.new(type: 4, name: "MR", kind: :bit,  writable: true, numbering: :hexdec, aliases: %w[M]),
        Device.new(type: 5, name: "B",  kind: :bit,  writable: true, numbering: :hex, aliases: []),
        Device.new(type: 6, name: "LR", kind: :bit,  writable: true, numbering: :hexdec, aliases: %w[L]),
        # **CR はインデックス修飾ができません。** 番号は空けたまま残します
        Device.new(type: 7, name: "CR", kind: :bit,  writable: false, numbering: :hexdec,
                   aliases: [], supported: false),
        Device.new(type: 8, name: "T",  kind: :bit,  writable: false, numbering: :dec,
                   aliases: [], float: false),
        Device.new(type: 9, name: "C",  kind: :bit,  writable: false, numbering: :dec,
                   aliases: [], float: false),
      ])
    end

    # 三菱 Q シリーズ
    #
    # **`R` と `ZR` は同じファイルレジスタです。** バンク付きの見え方と通し番号の
    # 見え方の違いで、実体は同じものです。faRuby 自身は ZR だけを使います。
    def self.melsec
      @melsec ||= new([
        Device.new(type: 0, name: "D",  kind: :word, writable: true, numbering: :dec, aliases: []),
        Device.new(type: 1, name: "W",  kind: :word, writable: true, numbering: :hex, aliases: []),
        Device.new(type: 2, name: "R",  kind: :word, writable: true, numbering: :dec, aliases: []),
        Device.new(type: 3, name: "ZR", kind: :word, writable: true, numbering: :dec, aliases: []),
        Device.new(type: 4, name: "M",  kind: :bit,  writable: true, numbering: :dec, aliases: []),
        Device.new(type: 5, name: "L",  kind: :bit,  writable: true, numbering: :dec, aliases: []),
        Device.new(type: 6, name: "B",  kind: :bit,  writable: true, numbering: :hex, aliases: []),
        Device.new(type: 7, name: "X",  kind: :bit,  writable: true, numbering: :hex, aliases: []),
        Device.new(type: 8, name: "Y",  kind: :bit,  writable: true, numbering: :hex, aliases: []),
      ])
    end
  end
end
