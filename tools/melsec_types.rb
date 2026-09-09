# frozen_string_literal: true

module FaRuby
  # 三菱の型を合わせる
  #
  # **GX Works2 は型をまたぐ代入も比較も通しません。** KV は黙って広げて
  # くれたので、生成器の元になっている KV スクリプトには 16 ビットを 32 ビットへ
  # そのまま入れる箇所も、整数と実数を直に比べる箇所もいくつもあります。
  #
  # **1 か所ずつ変換を書き足すのは無理があります。** 命令ごとに事情が違い、
  # 抜けたところは変換にかけるまで分かりません。そこで、出来上がった文の
  # 両辺の型を見て、狭いほうを広げる規則をここに 1 つだけ置きます。
  #
  # 型はラベルの控えから引きます (tools/devices.rb が配ったもの)。生成器が
  # 指したものがそのまま型になるので、表を別に持つ必要がありません。
  class MelsecTypes
    # 広さの順。**狭いほうを広げます**
    ORDER = { int: 0, long: 1, real: 2 }.freeze

    # **32 ビットを 16 ビットへ切り詰めるところはビット列を経由します。**
    # `DINT_TO_INT` は範囲を検査し、iQ-R は 60000 を書こうとすると
    # 「データ変換できない不正」で CPU が止まります (`$D320U = 60000`)。
    # faRuby が欲しいのは値の変換ではなくビット列です。
    #
    # GX Works2 (Q) は検査せず黙って切り詰めていました。**機種で分けません。**
    # 分けるとどちらかだけ直して忘れることになります。
    NARROW = "WORD_TO_INT(DINT_TO_WORD(%s))"

    CONVERSION = {
      [:int, :long] => "INT_TO_DINT", [:long, :int] => "DINT_TO_INT",
      [:int, :real] => "INT_TO_REAL", [:real, :int] => "REAL_TO_INT",
      [:long, :real] => "DINT_TO_REAL", [:real, :long] => "REAL_TO_DINT",
    }.freeze

    # 数だけの項。**どちらにも入ります** (`VMRV[i] := 4;` は通る)
    LITERAL = /\A-?\d+\z/

    # 変換で包んだところの目印。型を数えるときだけ使います
    MARKER = { int: "TYPEINT", long: "TYPELONG", real: "TYPEREAL" }.freeze

    # 型の付く項
    #
    # **添字とメンバまで含めて 1 つです。** `VMSLOT[VMREGSLOT + a].SLNUM` を
    # 途中で切ると、中の `a` (16 ビット) まで広げてしまいます。関数名は
    # 後ろの `(` で外します。
    TERM = /\b[A-Z][A-Z0-9]*(?:\[[^\]]*\])?(?:\.[A-Z0-9]+)?\b(?!\s*\()/

    def initialize(labels, device_set)
      @labels = labels
      @device_set = device_set
    end

    # 文の型を合わせる。**合っていればそのまま返します**
    def coerce(statement)
      code, comment = split_comment(statement)
      operation = split_operation(code)
      return statement if operation.nil?

      rewritten = rewrite(code, *operation)
      rewritten.nil? ? statement : rewritten + comment
    end

    # 式の型。**いちばん広い項に合わせます**
    def type_of(expr)
      found = types_in(expr)
      return nil if found.empty?

      found.max_by { |type| ORDER.fetch(type) }
    end

    # 式に出てくる型。**混ざっていれば 2 つ以上返ります**
    #
    # 変換で包んだところは包んだ後の型で数えます。包む前の項まで数えると、
    # 直したものまで混ざって見えます。
    def types_in(expr)
      masked(expr).scan(TERM).filter_map { |term| type_of_term(term) }.uniq - [:bool]
    end

    # 変換で包んだところを、その型の目印に置き換える
    #
    # **添字を先に潰します。** `VMFSLOT[(VMCURPOOL) / 4 + b]` のように添字の
    # 中に括弧があり、そのままだと変換の括弧と見分けが付きません。
    def masked(expr)
      text = expr.gsub(/\[[^\]]*\]/, "[]")
      names = CONVERSION.values + %w[WORD_TO_INT DINT_TO_WORD DWORD_TO_DINT DINT_TO_DWORD]
      loop do
        replaced = text.gsub(/\b(#{names.join("|")})\(([^()]*)\)/) do
          MARKER.fetch(result_type(Regexp.last_match(1)))
        end
        return text if replaced == text

        text = replaced
      end
    end

    # 式の項をすべて同じ型に揃える
    #
    # **式ごと包まずに項ごとに変換します。** `VMTEMP32L + VMSTRCOUNT` のように
    # 1 つの式の中で幅が混ざるところがあり、外から包んでも中は直りません。
    def unify(expr, target)
      return expr if target.nil?

      converted = expr.gsub(TERM) do |term|
        type = type_of_term(term)
        type.nil? || type == :bool || type == target ? term : convert(term, type, target)
      end
      case target
      when :real then real_literals(converted)
      when :int then signed_words(converted)
      else converted
      end
    end

    # 16 ビットのビット列は符号付きで書く
    #
    # **`VMTEMP32 := 65408;` は入りません。** INT は -32768〜32767 です。
    # 生成器が置くのはビット列 (-Infinity の上位ワード 0xFF80 など) なので、
    # 同じビット列を表す負の数に直します。KV の EM は符号なしでした。
    def signed_words(expr)
      outside_index(expr) do |part|
        part.gsub(/(?<![\w.])(\d+)(?![\w.])/) do
          value = Regexp.last_match(1).to_i
          value > 32_767 && value <= 65_535 ? (value - 65_536).to_s : value.to_s
        end
      end
    end

    # 実数と比べる数は実数で書く
    #
    # **`VMSLOTF[i].SLNUM <> 0` は通りません。** 0 は整数なので型が合いません。
    # 添字の中は数えません。レジスタ番号は整数のままです。
    def real_literals(expr)
      outside_index(expr) { |part| part.gsub(/(?<![\w.])(\d+)(?![\w.])/) { "#{Regexp.last_match(1)}.0" } }
    end

    # 添字の外だけを書き換える
    def outside_index(expr)
      expr.split(/(\[[^\]]*\])/).each_with_index.map { |part, i| i.odd? ? part : yield(part) }.join
    end

    def split_operation(code)
      return nil if code.start_with?("FOR ")

      if (m = code.match(/\A(?<lhs>[^=<>]+?)\s*:=\s*(?<rhs>.+?);\z/))
        [":=", m[:lhs], m[:rhs]]
      elsif (m = code.match(/\A(?<head>IF|ELSIF)\s+(?<lhs>.+?)\s*(?<op><=|>=|<>|=|<|>)\s*(?<rhs>.+?)\s+THEN\z/))
        [m[:op], m[:lhs], m[:rhs], m[:head]]
      end
    end

    private

    attr_reader :labels, :device_set

    # 変換を挟んだ文。要らなければ nil
    def rewrite(_code, operator, lhs, rhs, head = nil)
      left = type_of(lhs)
      right = type_of(rhs)

      if operator == ":="
        return nil if left.nil?

        "#{lhs} := #{unify(rhs, left)};"
      else
        wide = [left, right].compact.max_by { |type| ORDER.fetch(type) }
        return nil if wide.nil?

        "#{head} #{unify(lhs, wide)} #{operator} #{unify(rhs, wide)} THEN"
      end
    end

    def convert(expr, from, to)
      return expr if from == to
      return format(NARROW, expr.strip) if from == :long && to == :int

      "#{CONVERSION.fetch([from, to])}(#{expr.strip})"
    end

    # 末尾のコメントは触らない
    def split_comment(statement)
      index = statement.index("(*")
      index ? [statement[0...index].rstrip, statement[index..].prepend("   ")] : [statement, ""]
    end

    # 変換の結果の型
    RESULT_TYPES = { "WORD_TO_INT" => :int, "DINT_TO_WORD" => :int,
                     "DWORD_TO_DINT" => :long, "DINT_TO_DWORD" => :long }.freeze

    def result_type(name) = RESULT_TYPES[name] || CONVERSION.key(name).last

    def type_of_term(term)
      return nil if term.match?(LITERAL)

      marked = MARKER.key(term)
      return marked if marked

      return :bool if %w[TRUE FALSE].include?(term)
      return :int if term.match?(/\AZ[1-9]\z/)              # インデックスレジスタ
      return :int if term.match?(/\AK4[A-Z]+\d+Z\d\z/)      # 桁指定 16 個
      return :long if term.match?(/\AK8[A-Z]+\d+Z\d\z/)     # 桁指定 32 個

      if (m = term.match(/\A([A-Z]+)\d+Z\d\z/))             # ラダーのデバイス
        return device_set.bit_devices.any? { |d| d.name == m[1] } ? :bool : :int
      end

      name, member = term.match(/\A([A-Z0-9]+)(?:\[[^\]]*\])?(?:\.([A-Z0-9]+))?\z/)&.captures
      return nil unless name

      member ? member_type(name, member) : label_type(name)
    end

    # **型は IEC の綴りで持っています** (tools/devices.rb)。取り込みの CSV が
    # その綴りで、貼り付けの表の日本語はそこから作ります。
    def label_type(name)
      type = labels[name]&.type or return nil
      element = type[/\AARRAY \[[^\]]*\] OF (.+)\z/, 1] || type
      case element
      when "REAL" then :real
      when "DINT" then :long
      when "INT" then :int
      end
    end

    # 構造体のメンバ。**同じ名前でも重ねた配列で型が変わります**
    def member_type(array, member)
      return :int if member == MelsecDevices::TAG
      return :int if MelsecDevices::WORDS.include?(member)

      array.end_with?("F") ? :real : :long
    end
  end
end
