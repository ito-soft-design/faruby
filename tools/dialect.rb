# frozen_string_literal: true

require_relative "vm_constants"
require_relative "devices"
require_relative "device_set"
require_relative "melsec_types"
require_relative "opcode_table"

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
    include VmConstants

    # 機種の一覧。**設定の `models:` の見出しはこの名前です**
    def self.models = all.map(&:model)

    def self.all = CLASSES.map(&:new)

    # 機種名から綴り方を引く
    def self.for(model)
      all.find { |dialect| dialect.model == model } ||
        raise(ArgumentError, "知らない機種です: #{model.inspect} (#{models.join(', ')})")
    end

    # 書き出し先 (plc の下)。**エンジニアリングツールのプロジェクトと同じ場所**で、
    # 末尾のフォルダ名が機種名そのものです
    #
    #   keyence/KV-5000    KV Studio のプロジェクト
    #   mitsubishi/Q       GX Works2 のプロジェクト
    def directory = "#{vendor}/#{model}"

    # デバイスの指し方。**綴り方と対で決まります**
    def devices_for(layout, emitter) = KvDevices.new(layout, emitter)

    # 1 文を綴り直す
    def statement(text) = text

    # コメント 1 行
    def comment(text) = text.empty? ? "'" : "' #{text}"

    # ファイルレジスタのバンクを選ぶ。nil を返すと行そのものを出さない
    def select_bank(bank) = "FRSET(#{bank})"

    # 実数を整数へ代入したときに四捨五入されるか
    #
    # **KV スクリプトは 0 方向へ切り捨てます** (実機で確認済み)。生成コードは
    # `to_i` / `floor` / `round` とデバイスへの書き込みでそれを当てにしています。
    def rounds_float_to_int? = false

    # この機種で出す命令を選ぶ
    #
    # **新しい機種は段階を追って育てます。** KV 版も整数から始めて、メソッド・
    # ブロック・配列・文字列と足しながら、都度実機で確かめてきました
    # ([ロードマップ](../doc/roadmap.md))。一度に全部書き上げてから初めて
    # 動かすと、機種差がまとめて降ってきます。
    #
    # **外した命令は「未知のオペコード」で止まります。** 使ったプログラムが
    # 静かに壊れることはありません。
    def select_opcodes(opcodes) = opcodes

    # 指せないデバイス種別。**分岐ごと生成コードから外します**
    #
    # 綴り方の違いではなく、その機種で書けない文です。外した種別は VM が
    # 知らない種別として扱い、使おうとしたプログラムは実行時に止まります。
    def unsupported_devices = []

    # Ruby プログラムから触れるラダーのデバイス
    #
    # **メーカーごとの表から、この機種が指せないものを外したもの**です。
    # 外した番号は空けたまま残します (tools/device_set.rb)。
    def device_set = @device_set ||= base_device_set.without(*unsupported_devices)

    def base_device_set = DeviceSet.keyence

    # 1 ワードに置ける、本物の値とぶつからない番号
    #
    # 「どの群でもない」「探している文字が無い」を表すのに使います。
    # **三菱の INT は符号付きなので 65535 が入りません。** 上限が違うだけで
    # 意味は同じです。
    def word_sentinel = 65_535

    # スクリプトと一緒に出す付き物。名前 => 中身
    #
    # **KV は変数を宣言しません。** デバイスを直に指すので、生成物は
    # スクリプトだけです。三菱はラベルを先に登録する必要があるため、
    # ここでその一覧を出します。
    def companion_files(_devices) = {}

    # 出来上がったスクリプトに最後に手を入れる
    #
    # **1 文ずつでは直せないものだけです。** 前後の行を見ないと分からない
    # ものがここに来ます。
    def finish(source, _devices) = source

    # スクリプトを分けるか
    #
    # **KV Studio には 1 スクリプトの上限があります** (文字数と、対のない
    # LABEL / CJ / GOTO の数)。ステップのループもラダーに置くしかないので、
    # 命令の振り分けを組ごとの別スクリプトに分け、ラダーが順に呼びます。
    #
    # **三菱にはその上限がありません。** 1 本にまとめると、組ごとの関門
    # (「自分の担当か」の判定と、実行済みの目印) がまるごと要らなくなり、
    # ステップのループも ST の中に置けます。
    def splits_scripts? = true

    # ビットデバイスに真偽を書く
    #
    # **KV スクリプトでも ST でも `TRUE` / `FALSE` の代入で書けます。**
    # 以前はタイマ・カウンタの接点だけ `SET` / `RES` を使い、他は 1 / 0 を
    # 代入していましたが、種類による違いは要りませんでした。
    def write_bit(device, on) = "#{device} = #{on ? 'TRUE' : 'FALSE'}"
  end

  # KV-5000 の KV スクリプト。生成器が組み立てる形そのもの
  class KvsDialect < Dialect
    def vendor = "keyence"
    def model = "KV-5000"
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
  #
  # 綴り方以外の違いが 1 つあります。**タイマ・カウンタ (T / C) は使えません。**
  class StDialect < Dialect
    def vendor = "keyence"
    def model = "KV-X500"
    def name = "ST"
    def extension = "st"

    # バンクは常に 0 なので選ぶ手立てが無い
    def select_bank(_bank) = nil

    # **ST の実数→整数は四捨五入です** (実機で確認済み)。
    #
    # KV-5000 では `3.7` が 3、`-2.7` が -2 でしたが、KV-X500 では 4 と -3 に
    # なりました。`to_i` が -3、その上に建つ `floor` が -4 とずれます。
    # 生成側で丸めた向きを見て 1 だけ戻します。
    def rounds_float_to_int? = true

    # **タイマ・カウンタは ST では読み取りもできません。**
    #
    # KV-5000 の KV スクリプトでは接点 (`T0:Z6`) と現在値 (`T0.D:Z6`) を
    # 読めましたが、KV-X500 で変換を通すとどちらも通りませんでした
    # (KV Studio が読み出しもできないと出します)。綴り替えでは直らないので、
    # 分岐ごと外します。
    def unsupported_devices = [DEVICE_TYPE_T, DEVICE_TYPE_C]

    # コメントの綴り。**GX Works2 は (* *) なので機種で差し替えます**
    def comment(text) = wrap_comment(text)

    def statement(text)
      code, note = split_comment(text)
      "#{render(code)}#{note ? "   #{wrap_comment(note)}" : ""}"
    end

    # 行コメント 1 つ分。IEC の // が使えるならそちら
    def wrap_comment(text) = text.empty? ? "//" : "// #{text}"

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

  # MELSEC Q の ST (GX Works2)
  #
  # **綴りは KV-X500 の ST とほぼ同じで、違うのはコメントとデバイスの指し方**
  # です。指し方は tools/devices.rb の MelsecDevices が持ちます。
  #
  # 実機で確かめた性質は doc/melsec.md にあります。KV と同じだったもの
  # (整数除算の丸め・入れ子 EXIT・実数の丸め・ビット指定の制約) が多く、
  # 判断をやり直さずに済みました。
  class MelsecDialect < StDialect
    def vendor = "mitsubishi"
    def model = "Q"
    def name = "ST (GX Works2)"

    # GX Works2 のコメントは (* *)。// は使いません
    def wrap_comment(text) = text.empty? ? "(* *)" : "(* #{text} *)"

    # **ラベルの控えは綴り方が持ちます。** 生成はファイルごとに別の emitter で
    # 行うので、デバイス層に持たせると 1 ファイルぶんしか集まりません。
    # 綴り方は 1 回の生成で 1 つなので、ここが全体の受け皿になります。
    def devices_for(layout, emitter) = MelsecDevices.new(layout, emitter, labels)

    def labels = @labels ||= {}

    # 型を合わせてから出す
    #
    # **GX Works2 は型をまたぐ代入も比較も通しません。** KV は黙って広げて
    # くれたので、命令の定義には整数と実数を直に比べる箇所も、16 ビットを
    # 32 ビットへそのまま入れる箇所もあります。1 か所ずつ書き足すのは無理が
    # あるので、出来上がった文の両辺を見て狭いほうを広げます
    # (tools/melsec_types.rb)。
    def statement(text)
      types.coerce(super)
    end

    def types = @types ||= MelsecTypes.new(labels, device_set)

    # タイマ・カウンタは MELSEC にもありますが、**段階 1 では扱いません**。
    # 命令を絞っているうちはデバイスも絞ります
    def unsupported_devices = [DEVICE_TYPE_T, DEVICE_TYPE_C]

    # 段階 1 — 整数・分岐・ループ・デバイスの読み書き
    #
    # **新しい機種は段階を追って育てます** (doc/melsec.md)。メソッド・ブロック・
    # 配列・ハッシュ・文字列は段階 2 以降です。外した命令は「未知のオペコード」で
    # 止まるので、使ったプログラムが静かに壊れることはありません。
    STAGE1 = %i[
      OP_NOP OP_MOVE OP_LOADL OP_LOADI OP_LOADINEG OP_LOADI__1
      OP_LOADI_0 OP_LOADI_1 OP_LOADI_2 OP_LOADI_3 OP_LOADI_4 OP_LOADI_5
      OP_LOADI_6 OP_LOADI_7 OP_LOADI16 OP_LOADI32
      OP_LOADNIL OP_LOADSELF OP_LOADT OP_LOADF
      OP_GETGV OP_SETGV OP_GETIDX OP_SETIDX
      OP_JMP OP_JMPIF OP_JMPNOT OP_JMPNIL
      OP_ADD OP_ADDI OP_SUB OP_SUBI OP_MUL OP_DIV
      OP_EQ OP_LT OP_LE OP_GT OP_GE
      OP_RETURN OP_STOP
    ].freeze

    # ステージ 2 — メソッドとブロック
    #
    # `def` と `10.times { }` が動くようになります。**配列・ハッシュ・文字列は
    # まだ**なので、それらを触ると「未知のオペコード」で止まります。
    #
    # `OP_TCLASS` と `OP_LOADSYM` と `OP_DEF` は `def` の出力に混ざります。
    # `OP_GETUPVAR` / `OP_SETUPVAR` はブロックの外側の変数を触ります。
    STAGE2 = %i[
      OP_SSEND OP_SEND OP_SENDB OP_ENTER OP_BREAK
      OP_BLOCK OP_METHOD OP_DEF OP_TCLASS OP_LOADSYM
      OP_GETUPVAR OP_SETUPVAR
    ].freeze

    # ステージ 3 — 配列・ハッシュ・文字列
    #
    # **作る側の命令だけです。** `push` や `length` や `keys` といったメソッドは
    # ステージ 2 で `OP_SEND` を入れた時点で乗っています (組み込みメソッドの
    # 振り分けが丸ごと出るため)。だから 6 個で足ります。
    STAGE3 = %i[OP_SETCONST OP_ARRAY OP_ARRAY2 OP_STRING OP_STRCAT OP_HASH].freeze

    # この機種に載せる命令
    #
    # **段を追って増やしてきました** ([ロードマップ](../doc/roadmap.md))。一度に
    # 全部書き上げてから初めて動かすと、機種差がまとめて降ってきます。実際
    # ステージ 2 で、KV との指し方の違いに由来する穴が 2 つ出ました。
    #
    # いまは全部載っています。**段の区切りは記録として残します。**
    STAGES = (STAGE1 + STAGE2 + STAGE3).freeze

    def select_opcodes(opcodes)
      opcodes.select { |op| STAGES.include?(OpcodeTable::MRUBY_OPCODES[op.code]&.first) }
    end

    # ラベルと構造体の一覧
    #
    # **三菱はデバイスを直に指せない場所があります。** 添字を付けた
    # 構造体の配列で書くので、その定義を先に登録しておく必要があります。
    # 生成コードが指したものをそのまま出すので、手で写す手間も食い違いも
    # ありません。
    # **三菱の INT は符号付きです** (-32768〜32767)。65535 は入りません
    def word_sentinel = 32_767

    # **上限が無いので 1 本にまとめます。** 組分けは入れ子にして残します
    # (担当外の組を比較 1 回で飛ばせるのは速度に効くため)
    def splits_scripts? = false

    # **キーエンスの種別は三菱にありません。** 名前も番号の数え方も違います
    def base_device_set = DeviceSet.melsec

    # 三菱の表に T / C は無いので、外すものもありません
    def unsupported_devices = []

    # 中身の無い分岐を埋める
    #
    # **GX Works2 は文の無い分岐を通しません。** KV スクリプトでも KV-X500 の
    # ST でも通るので、生成器は `OP_NOP` や「ここへは来ない」の分岐を注釈だけで
    # 閉じています。そこに何もしない代入を 1 つ置きます。
    #
    # 置く文は tools/devices.rb が決めます (誰も読まない 1 語への代入)。
    def finish(source, devices)
      noop = statement(devices.noop_statement)
      lines = source.split("\n")
      opened = nil
      filled = []
      lines.each do |line|
        code = line.split("(*").first.to_s.strip
        if opened && closes_block?(code)
          filled << "#{opened}#{noop}"
        end
        opened = nil if !code.empty? && !opens_block?(code)
        opened = "#{line[/\A */]}  " if opens_block?(code)
        filled << line
      end
      filled.join("\n")
    end

    def companion_files(devices)
      { "faruby_labels.tsv" => devices.label_table,
        "faruby_labels.md" => label_document(devices) }
    end

    private

    # 先頭デバイスを手で設定するラベル
    def structure_label_rows(devices)
      devices.structure_labels.map { |name, device| "| `#{name}` | `#{device}` |" }.join("\n")
    end

    def opens_block?(code) = code.end_with?("THEN") || code.end_with?("DO") || code == "ELSE"
    def closes_block?(code) = code.start_with?("ELSIF", "END_") || code == "ELSE"

    def label_document(devices)
      structures = devices.structure_definitions.map { |name, members|
        rows = members.map { |member, type| "| #{member} | #{type} |" }
        "### #{name}\n\n| メンバ | データ型 |\n|---|---|\n#{rows.join("\n")}\n"
      }
      <<~TEXT
        # faRuby のラベル (#{model})

        `rake vm_core` が生成します。手で編集しないでください。

        ## 手順

        1. 下の構造体を「構造体設定」に登録します
        2. `faruby_labels.tsv` をグローバルラベルの表に貼り付けます
        3. **構造体の配列 #{devices.structure_labels.size} つに先頭デバイスを設定します** (下の表)

        **構造体を先に登録します。** ラベルの型の欄が構造体名を指すためです。

        ## 構造体の配列に先頭デバイスを設定する

        **ここだけ手作業です。** GX Works2 は構造体の先頭デバイスを別画面で
        持っていて、表には「詳細設定」の押しボタンが出るだけなので、
        貼り付けでは渡せません。

        | ラベル | 先頭デバイス |
        |-------|------------|
        #{structure_label_rows(devices)}

        **同じデバイスに重ねます。** 値が 32 ビット整数か実数か 16 ビット 2 つかは
        実行時にしか決まらないためです。重なっているのは意図したとおりです。

        ## 構造体

        faRuby のスロットは 4 ワード (タグ 1 + 値 2 + 予備 1) です。**同じ
        4 ワードを 3 通りに見ます。** 値が 32 ビット整数か実数か 16 ビット
        2 つかは実行時にしか決まらないので、重ねて割り付けます。

        #{structures.join("\n")}
      TEXT
    end
  end

  class Dialect
    # 対応している機種。**増やすときはここに足すだけ**で、生成 (`rake vm_core`)
    # も設定の `models:` もこの一覧から決まります。
    CLASSES = [KvsDialect, StDialect, MelsecDialect].freeze
  end
end
