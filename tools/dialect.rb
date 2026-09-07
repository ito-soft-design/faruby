# frozen_string_literal: true

module FaRuby
  # 生成コードの綴り方
  #
  # **命令の意味は機種によらず同じで、違うのは文の書き方だけです。**
  # デバイスの指し方 (`EM0:Z9`、`.L`、`.F`) は KV-5000 の KV スクリプトでも
  # KV-X500 の ST でも同じなので、差し替えるのは代入・条件・ループ・
  # いくつかの関数名に限られます。
  #
  # 生成器は KV スクリプトの形で文を組み立て、ここで綴り直します。
  # KV 向けは素通しなので、この層を挟んでも出力は 1 バイトも変わりません。
  class Dialect
    # 1 文を綴り直す
    def statement(text) = text

    # コメント 1 行
    def comment(text) = text.empty? ? "'" : "' #{text}"

    # ファイルレジスタのバンクを選ぶ。nil を返すと行そのものを出さない
    def select_bank(bank) = "FRSET(#{bank})"

    # ビットデバイスに真偽を書く
    #
    # **KV スクリプトでも ST でも `TRUE` / `FALSE` の代入で書けます。**
    # 以前はタイマ・カウンタの接点だけ `SET` / `RES` を使い、他は 1 / 0 を
    # 代入していましたが、種類による違いは要りませんでした。
    def write_bit(device, on) = "#{device} = #{on ? 'TRUE' : 'FALSE'}"
  end

  # KV-5000 の KV スクリプト。生成器が組み立てる形そのもの
  class KvsDialect < Dialect
    def name = "KV スクリプト"
    def extension = "kvs"
  end

  # KV-X500 の ST (IEC 61131-3 準拠の構造化テキスト)
  #
  # 違うのは次の点だけです。
  #
  #   代入      a = b            → a := b;
  #   コメント   ' text           → // text
  #   条件      ELSE IF / END IF → ELSIF / END_IF;
  #   ループ     FOR a = b TO c   → FOR a := b TO c DO
  #             NEXT             → END_FOR;
  #   打ち切り   BREAK            → EXIT;
  #   シフト     SLA / SRA        → SHL / SHR
  #   符号反転   NEG(x)           → -(x)
  #   バンク     FRSET(n)         → 無し (常に 0)
  #
  # **`INC(x)` は使わず `x := x + 1;` に開きます。** ST にあるか分からない
  # ためで、開いても意味は同じです。
  class StDialect < Dialect
    def name = "ST"
    def extension = "st"

    # バンクは常に 0 なので選ぶ手立てが無い
    def select_bank(_bank) = nil

    def comment(text) = text.empty? ? "//" : "// #{text}"

    def statement(text)
      code, note = split_comment(text)
      "#{render(code)}#{note ? "   // #{note}" : ""}"
    end

    private

    # 行末の KV コメント (' より後ろ) を切り離す
    #
    # 文字列リテラルは生成コードに出てこないため、最初の ' で切って構いません。
    def split_comment(text)
      index = text.index("'")
      return [text.rstrip, nil] unless index

      [text[0...index].rstrip, text[(index + 1)..].strip]
    end

    def render(code)
      case code
      when "" then ""
      when "NEXT" then "END_FOR;"
      when "BREAK" then "EXIT;"
      when "ELSE" then "ELSE"
      when "END IF" then "END_IF;"
      when /\AELSE IF (.+) THEN\z/ then "ELSIF #{functions(Regexp.last_match(1))} THEN"
      when /\AIF (.+) THEN\z/ then "IF #{functions(Regexp.last_match(1))} THEN"
      when /\AFOR (.+?) = (.+?) TO (.+?)( STEP (.+))?\z/ then for_open(Regexp.last_match)
      when /\AINC\((.+)\)\z/ then increment(Regexp.last_match(1))
      when /\AFRSET\(\d+\)\z/ then ""
      when /\A[A-Z]+\([^=]*\)\z/ then "#{code};"   # SET / RES などの呼び出し
      else assignment(code)
      end
    end

    def for_open(match)
      step = match[5] ? " BY #{functions(match[5])}" : ""
      "FOR #{match[1]} := #{functions(match[2])} TO #{functions(match[3])}#{step} DO"
    end

    def increment(target) = "#{target} := #{target} + 1;"

    # 残りはすべて代入。**最初の = だけを置き換えます。**
    # 右辺に = は現れません (比較は条件の中だけ)
    def assignment(code)
      target, expr = code.split(" = ", 2)
      raise ArgumentError, "代入に見えません: #{code.inspect}" unless expr

      "#{target} := #{functions(expr)};"
    end

    # 関数名だけを差し替える。引数の中身はそのまま
    def functions(expr)
      expr.gsub(/\bSLA\(/) { "SHL(" }
          .gsub(/\bSRA\(/) { "SHR(" }
          .gsub(/\bNEG\(/) { "-(" }
    end
  end
end
