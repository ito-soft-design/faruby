# frozen_string_literal: true

require_relative "device_syntax"

module FaRuby
  # デバイスの割り付け表
  #
  # **割り付けは PLC ではなくプログラムのものです。** 同じ PLC に別の
  # プログラムを載せれば割り付けも変わるので、接続設定ではなくプログラムの
  # 隣に置き、プログラムの先頭 1 行でどの表を使うかを書きます。
  #
  #     # devices: line2.devices.rb
  #
  # 表は Ruby で書きます。**読むときに本当に実行します。** 連番の配線を
  # 手で並べずに済むのが値打ちで、16 点の入力を 1 行で書けます。
  #
  #     FaRuby.devices do
  #       map "start", "R0"
  #       16.times { |i| map "in_#{i}", "R#{100 + i}" }
  #     end
  #
  # 名前と割り付け先が正しいかはここでは見ません。**実デバイスと重なるかは
  # メーカーで違う**ので (三菱には X / Y がある)、機種が決まる
  # DeviceSyntax まで持っていってから検査します。
  class DeviceMap
    # プログラムの先頭に書く宣言
    DECLARATION = /\A#\s*devices:\s*(\S+)/

    # 名前 => 実デバイス
    attr_reader :mapping

    # 表のファイルのパス (宣言が無ければ nil)
    attr_reader :path

    def initialize(mapping = {}, warn_unmapped: false, path: nil)
      @mapping = mapping
      @warn_unmapped = warn_unmapped
      @path = path
    end

    # 表を通らずに実デバイスを直に書いた名前を知らせるか
    def warn_unmapped? = @warn_unmapped

    def size  = @mapping.size
    def empty? = @mapping.empty?

    def self.empty = @empty ||= new

    # プログラムから表を引く。宣言が無ければ空の表
    def self.for_program(source_path)
      name = declaration(File.read(source_path, encoding: "utf-8"))
      return empty unless name

      path = File.absolute_path?(name) ? name : File.join(File.dirname(source_path), name)
      unless File.file?(path)
        raise CodegenError,
              "割り付け表が見つかりません: #{path} " \
              "(#{File.basename(source_path)} の `# devices:` 行)"
      end

      load_file(path)
    end

    # `# devices:` 行を探す。最初の 1 本だけを使う
    def self.declaration(source)
      source.lines.each do |line|
        return Regexp.last_match(1) if line.match(DECLARATION)
      end
      nil
    end

    # 表のファイルを実行して読む
    #
    # `load` を使うのは、同じファイルを読み直せるようにするためです
    # (`require` は 2 度目を黙って飛ばします)。
    def self.load_file(path)
      builder = Builder.new(path)
      previous = @collector
      @collector = builder
      begin
        Kernel.load(path)
      rescue CodegenError
        raise
      rescue SyntaxError, StandardError => e
        raise CodegenError, "割り付け表を読めません: #{path} (#{e.class}: #{e.message})"
      ensure
        @collector = previous
      end

      builder.to_device_map
    end

    # FaRuby.devices のブロックを受ける係
    def self.collect(&block)
      raise CodegenError, "FaRuby.devices にはブロックを渡してください" unless block
      unless @collector
        raise CodegenError,
              "FaRuby.devices は割り付け表のファイルの中だけで使えます " \
              "(プログラムの先頭に `# devices: ファイル名` と書いて指します)"
      end

      @collector.instance_eval(&block)
      nil
    end

    # 表を組み立てる係。`FaRuby.devices` のブロックの中の self
    #
    # **ブロックが 2 本あっても足し合わせます。** 入力と出力を別の
    # ブロックに分けて書けます。
    class Builder
      def initialize(path)
        @path = path
        @mapping = {}
        @warn_unmapped = false
      end

      # 抽象的な名前を実デバイスに割り付ける
      #
      # **1 点ずつ書きます。** 範囲で書けないのは、配線が連続している保証が
      # 無いためです。並んでいるなら繰り返しで書けます。
      def map(name, target)
        name = name.to_s
        if @mapping.key?(name)
          raise CodegenError,
                "#{File.basename(@path)}: #{name} が 2 度出ています " \
                "(#{@mapping[name]} と #{target})"
        end

        @mapping[name] = target.to_s
      end

      # 表を通らずに実デバイスを直に書いた名前を知らせる
      #
      # 全部を抽象化したい設備で `$R0` の直書きを見つけるためのものです。
      # 止めはしません。表は任意で、混ぜて使えるのが前提だからです。
      def warn_unmapped! = @warn_unmapped = true

      def to_device_map
        DeviceMap.new(@mapping, warn_unmapped: @warn_unmapped, path: @path)
      end
    end
  end

  # 割り付け表のファイルから呼ぶ入口
  def self.devices(&block) = DeviceMap.collect(&block)
end
