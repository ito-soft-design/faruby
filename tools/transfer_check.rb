# frozen_string_literal: true

require_relative "kvs_generator"

module FaRuby
  # KV Studio に取り込んだスクリプトと、生成したスクリプトを突き合わせる
  #
  # **どのファイルを取り込み直せばよいかを、PLC 側の中身から決めます。**
  # コミットの差分から数えると、取り込み忘れや、前回どこまで取り込んだかを
  # 覚えていない場合に合いません。実際に一度これで古いままのスクリプトが
  # 見つかっています。
  #
  # 使い方: KV Studio でニーモニックを書き出してから `rake transfer`
  #
  # 書き出したファイルの形式:
  #   ;<h1/>スクリプト名     スクリプトの始まり
  #   ;元のソース行          直後にそのまま並ぶ
  #   LD CR2002              変換後のラダー命令 (';' が付かない)
  #
  # ソースはこの後にもう一度、ラダー命令と交互に現れます。比べるのは
  # 最初のほうです。文字コードは Shift_JIS。
  class TransferCheck
    ENCODING = "windows-31j"

    Result = Struct.new(:name, :state, :detail) do
      def stale? = state != :same
    end

    # 書き出し先を探す。プロジェクト名が変わっても見つかるように glob で引く
    def self.find_mnemonic(dir = KvsGenerator.new.output_dir)
      Dir[File.join(dir, "**", "tmp", "*.mnm")].max_by { |path| File.mtime(path) }
    end

    def initialize(path, generator: KvsGenerator.new)
      @path = path
      @generator = generator
    end

    # [Result] を返す。並びはラダーに置く順
    def results
      transferred = parse
      @generator.generate.map do |name, content|
        stem = File.basename(name, ".*")   # 拡張子は機種で違う (.kvs / .st)
        want = content.split("\n").map(&:rstrip)
        got = transferred[stem]
        next Result.new(name, :missing, "取り込まれていません") if got.nil?

        diff = want.each_index.reject { |i| want[i] == got[i] }
        if diff.empty?
          Result.new(name, :same, "#{want.size} 行")
        else
          Result.new(name, :differs, "#{diff.size} 行違います (最初は #{diff.first + 1} 行目)")
        end
      end
    end

    private

    # スクリプト名 => 取り込まれているソース行
    #
    # 行数は生成物と同じだけ取ります。2 度目に現れる交互の並びまで
    # 読まないようにするためです。
    #
    # 見出しの書き方は機種で違います。**名前だけで引き当てます。**
    #
    #   KV-5000  ;<h1/>vm_01_init
    #   KV-X500  ;vm_01_init      直後に AREA_ST が 1 行入る
    def parse
      lines = decode(File.binread(@path)).split(/\r?\n/)
      sizes = @generator.generate.transform_keys { |name| File.basename(name, ".*") }
                        .transform_values { |content| content.split("\n").size }

      lines.each_with_index.with_object({}) do |(line, index), found|
        next unless line.start_with?(";")

        stem = line.sub(/\A;(<h1\/>)?/, "")
        size = sizes[stem] or next
        first = index + 1
        first += 1 if lines[first] == "AREA_ST"   # ST は区分の見出しが 1 行入る
        found[stem] = lines[first, size].map { |l| l.sub(/\A;/, "") }
      end
    end

    # 文字コードは機種で違う。**BOM で見分けます**
    #
    #   KV-5000  Shift_JIS (BOM 無し)
    #   KV-X500  UTF-16LE  (BOM FF FE)
    def decode(data)
      if data.start_with?("\xFF\xFE".b)
        data.force_encoding("UTF-16LE").encode("utf-8").sub("﻿", "")
      else
        data.force_encoding(ENCODING).encode("utf-8")
      end
    end
  end
end
