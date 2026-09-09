# frozen_string_literal: true

# デバイスの指し方
#
# **命令の意味と算法は機種によらず同じで、違うのはデバイスをどう指すかです。**
# 生成器 (KvsEmitter) は 2,600 行ありますが、そのほとんどは型の区分・エラー
# コード・文字列の扱いといった算法で、機種を増やしても変わりません。変わるのは
# ここに集めた十数個です。
#
# 三菱版をバックエンドごと別に書く道もありましたが、**算法をもう一組持つ**
# ことになります。`OP_SSEND` が `OP_SEND` の振り分けを重複して持っているせいで
# 起きた問題と同じものを、自分から作ることになるため採りませんでした。
#
# ## 機種による違い
#
#   KV      Z1 = EM7:Z9 * 4 + EM32:Z9 + Z9      アドレスを Z に組み立てて
#           EM1.L:Z1 = EM1.L:Z2                 修飾で指す
#
#   MELSEC  VMRV[VMOPA] := VMRV[VMOPB];         型付きラベル配列の添字
#
# KV は 1 本の Z でタグと値の両方を指し、MELSEC は配列を型ごとに分けます。
# **アドレス計算そのものが要らなくなる**ので、綴り替えでは届きません。

require_relative "memory_layout"
require_relative "vm_constants"

module FaRuby
  # インデックスレジスタの退避・復元
  #
  # **Z はラダーと共有する資源です。** faRuby が作業用に書き換えるので、
  # 実行の前後で内容が変わらないようにします (1 スキャンにつき 1 回)。
  # 退避先の指し方だけが機種で違い、手順は同じです。
  module SavesIndexRegisters
    # faRuby が書き換える Z レジスタ
    #
    # KV では Z11 / Z12 に特別な用途があり使用できません (実機で確認済み)。
    # 使えるのは Z1-Z10 で、faRuby は Z1-Z9 を使います。
    USED_Z = (1..9).to_a.freeze

    def save_index_registers
      @emitter.note "インデックスレジスタの退避"
      @emitter.note "Z はラダーと共有する資源のため、faRuby の実行前後で"
      @emitter.note "内容が変わらないようにする (1スキャンにつき1回)"
      USED_Z.each { |z| @emitter.line "#{z_save(z)} = Z#{z}" }
    end

    def restore_index_registers
      @emitter.note "インデックスレジスタの復元"
      USED_Z.each { |z| @emitter.line "Z#{z} = #{z_save(z)}" }
    end
  end

  # KV スクリプト / ST (KV-5000・KV-X500) のデバイスの指し方
  #
  # ブロック先頭は Z9 に載っています。ブロック内の固定位置はオフセットを
  # インデックス修飾で足して指します (`EM7:Z9`)。こうすることで、どの
  # インスタンスでも同じコードが動きます。
  #
  # **型サフィックスはデバイス側に付けます** (`EM16.L:Z9`)。`EM16:Z9.L` と
  # 書くと `.L` がインデックスレジスタに結合し、エラーにならないまま
  # 16 ビットアクセスに退化します (実機で 91 箇所やりました)。
  class KvDevices
    include VmConstants

    # アクセス幅とデバイスに付けるサフィックス
    #
    # **KV は幅をデバイス側に付けて選びます** (`DM0.L:Z6`)。三菱にこの綴りは
    # 無いので、この対応表も KV だけのものです。
    ACCESS_SUFFIX = { ACCESS_S => "S", ACCESS_U => "U", ACCESS_L => "L",
                      ACCESS_D => "D", ACCESS_F => "F" }.freeze

    include SavesIndexRegisters

    # インデックスレジスタの割り当て
    # Z1 = 主オペランド (通常は代入先の R[a])、Z2 = 副オペランド
    # Z3-Z8 はバイトコードフェッチとデバイステーブル参照が使う
    # Z9 = 実行中インスタンスのブロック先頭
    Z_PRIMARY = 1
    Z_SECONDARY = 2
    Z_INSTANCE = 9
    # OP_SETIDX の代入元。Z1 は参照、Z2 は添字が使うので3本目を割り当てる
    Z_VALUE = 3


    # 値スロットへの参照
    #
    # **呼ぶ側が使うのは「タグ」「値」「実数として」の 3 つだけです。**
    # どう指すかは機種が決めます。KV は 1 本の Z から、MELSEC は構造体の
    # 添字から作ります。
    #
    # 値は 32ビット整数としても単精度実数としても読めます。どちらで読むかは
    # 実行時のタグで決まるため、生成コードは両方を出しておいて IF で選びます。
    Slot = Struct.new(:tag, :value, :float, :word_ref) do
      # 値ワードを16ビット単位で指す (IEEE754 のビット列を直接書くときに使う)
      def word(offset) = word_ref.call(offset)
    end

    attr_reader :layout

    # emitter: 行を出す相手。**アドレスを Z に載せる行が要る**ため持ちます。
    # MELSEC は添字で直接指すので、その実装では行が出ません。
    def initialize(layout, emitter = nil)
      @layout = layout
      @emitter = emitter
      @slot_cache = {}
    end

    # --- インデックス修飾の基点 ---

    # 例: "EM0"。デバイス番号 0 からの相対を Z で指定する書き方に使う。
    # PC を指す layout.pc_addr とは別物なので混同しないこと
    def indexed_base = "#{layout.device_name}0"

    # 固定領域 (FM) をインデックス修飾で指すときの基点
    #
    # FM は ZF をバンクに分けたもの。スクリプトの先頭で FRSET でバンクを
    # 選んであるため、ここではバンクを意識せず 0-32767 のアドレスで指せる
    def fixed_indexed_base = "#{layout.fixed_device_name}0"

    # --- Z に載せたアドレスで 1 ワードを指す ---
    #
    # **区切り記号が機種で違います** (`EM0:Z3` と `D0Z3`)。生成コードは
    # インデックスレジスタを算法全体の一時変数に使っているので、そこは
    # 機種によらず同じまま、指し方だけを差し替えます。
    def word_at(z, offset = 0)  = "#{layout.device_name}#{offset}:Z#{z}"
    def fixed_at(z, offset = 0) = "#{layout.fixed_device_name}#{offset}:Z#{z}"

    # --- インスタンス相対のデバイス参照 ---

    # ブロック内の固定位置を指す (16ビット)
    def state(addr) = "#{layout.device_name}#{layout.offset_of(addr)}:Z#{Z_INSTANCE}"

    # ブロック内の固定位置を指す (32ビット)
    def state_long(addr) = "#{layout.device_name}#{layout.offset_of(addr)}.L:Z#{Z_INSTANCE}"

    # ブロック内の固定位置を実数として指す (デバイス書き込みの型合わせ用)
    def state_float(addr) = "#{layout.device_name}#{layout.offset_of(addr)}.F:Z#{Z_INSTANCE}"

    # Z に絶対アドレスを組み立てる式の末尾に足す項
    def block_offset(base) = "#{layout.offset_of(base)} + Z#{Z_INSTANCE}"

    # 実行中の irep の領域を指す項
    #
    # irep が複数になったため、バイトコード・定数プール・シンボル表の位置は
    # 定数ではありません。切り替え時に VM 状態へ写した値を使います。
    #
    # 固定領域 (FM) の位置は **絶対アドレス**で持ちます。FM は 0-32767 なので
    # Z に載り、インスタンスごとの先頭を足す必要がありません。
    # 可変領域 (EM) はブロック先頭からのオフセットなので Z9 を足します。
    def bytecode_offset   = state(layout.cur_bytecode_addr)
    def pool_offset       = state(layout.cur_pool_addr)
    def symbols_offset    = state(layout.cur_symbols_addr)
    def irep_table_offset = state(layout.irep_table_addr_addr)

    # 固定領域の位置。インスタンスごとに違うため先頭からの相対で組み立てる
    def fixed_offset(base) = "#{irep_table_offset} + #{layout.fixed_offset_of(base)}"

    def reg_offset = "#{state(layout.reg_base_addr)} + Z#{Z_INSTANCE}"

    # Z の退避先。インスタンスループの外で 1 回だけ触るので絶対アドレス
    def z_save(z) = layout.device(layout.z_save_addr(z))

    # --- ラダーのデバイスを指す ---

    # 幅を指定して読む。**値の式を返します**
    #
    # KV は幅をサフィックスで選べるので 1 つの式で済みます。文は出しません。
    def device_read(device, access, z) = "#{device.name}0.#{ACCESS_SUFFIX.fetch(access)}:Z#{z}"

    # 幅を指定して書く
    def device_write(device, access, z, source)
      @emitter.line "#{device_read(device, access, z)} = #{source.value}"
    end

    # 個別ビット
    def bit_ref(device, z) = "#{device.name}0:Z#{z}"

    # ワードデバイスから 1 ワードそのまま
    #
    # **中身を解釈しません。** 文字列のバイト列を運ぶだけなので、ビット列が
    # 保てれば符号は問いません。EM は既定が符号なしなので `.U` を付けます。
    def raw_word(device, z) = "#{device.name}0.U:Z#{z}"

    # --- ビットをずらす・重ねる ---

    # 桁数だけずらす。**桁数は変数で構いません**
    def shift(target, amount, left:)
      @emitter.line "#{target} = #{left ? "SLA" : "SRA"}(#{target}, #{amount})"
    end

    # ビット演算。**ワードのまま書けます**
    def bit_op(target, lhs, operator, rhs)
      @emitter.line "#{target} = #{lhs} #{operator} #{rhs}"
    end

    # --- Z に載せたアドレスの 32 ビット ---

    # 読む。**幅をデバイスに付けるので 1 つの式です**
    def long_at(z, offset, _scratch) = "#{layout.device_name}#{offset}.L:Z#{z}"

    def write_long_at(z, offset, source)
      @emitter.line "#{long_at(z, offset, nil)} = #{source.value}"
    end

    # --- 符号拡張 ---

    # 16 ビットオペランドを符号付きとして読み直す
    #
    # **EM は符号なしなので引いて直します。** ビット列は変わりません。

    def normalize_signed16(var)
      @emitter.if_("#{var} >= 32768") { @emitter.line "#{var} = #{var} - 65536" }
    end

    # bits ビットの値を符号拡張して 32 ビットスクラッチに置く
    #
    # **EM は符号なしなので上位ワードを手で埋めます。** 16 ビット未満の値は
    # 下位ワードも詰め直します。符号なしのまま引き算すると桁が壊れるためです。
    def sign_extend(value, bits)
      lo = @emitter.scratch_lo
      hi = @emitter.scratch_hi
      @emitter.line "#{lo} = #{value}"
      @emitter.line "#{hi} = 0"
      @emitter.if_("#{value} >= #{1 << (bits - 1)}") do
        @emitter.line "#{lo} = #{value} + #{0x1_0000 - (1 << bits)}" if bits < 16
        @emitter.line "#{hi} = 65535"
      end
    end

    # 符号を反転した値
    #
    # **16 ビットが 2 つで 32 ビットを作ります。** 下位に 0 - 値、上位は 0 か
    # 65535 (負なら全ビット 1)。KV の EM はサフィックス無しだと 16 ビット
    # 符号なしなので、そのままでは負の数を書けません。
    def negate(value)
      lo = state(layout.temp32_addr)
      hi = state(layout.temp32_addr + 1)
      @emitter.note "2の補数を32ビットで組み立てる"
      @emitter.line "#{lo} = 0 - #{value}"
      @emitter.line "#{hi} = 0"
      @emitter.if_("#{value} <> 0") { @emitter.line "#{hi} = 65535" }
      state_long(layout.temp32_addr)
    end

    # --- インスタンスループ ---

    # 実行するインスタンスを順に巡る
    #
    # **ブロック先頭そのものをループ変数にします。** インスタンス番号を別に
    # 持たずに済みます。instances が 1 でも同じ形にして経路を 1 本に保ちます。
    def each_instance
      @emitter.note "インスタンスごとの実行 (ブロック先頭を Z#{Z_INSTANCE} に載せる)"
      @emitter.note "instances = #{layout.instances}"
      @emitter.line "FOR Z#{Z_INSTANCE} = #{layout.base} TO #{layout.last_origin} " \
                    "STEP #{layout.instance_size}"
      @emitter.indent
      yield
      @emitter.dedent
      @emitter.line "NEXT"
    end

    # レジスタファイルを 0 で埋める
    #
    # **ワード単位で潰します。** スロット先頭の型タグも 0 (TT_EMPTY) になります。
    def clear_register_file(z)
      last = layout.reg_slot_addr(layout.max_regs) - 1
      @emitter.note "レジスタファイルクリア " \
                    "(ブロック先頭 +#{layout.offset_of(layout.reg_file_base)} から " \
                    "#{layout.max_regs}スロット × #{VmConstants::SLOT_WORDS}ワード)"
      @emitter.note "スロット先頭の型タグも 0 (TT_EMPTY) になる"
      @emitter.line "FOR Z#{z} = #{block_offset(layout.reg_file_base)} " \
                    "TO #{block_offset(last)}"
      @emitter.indent
      @emitter.line "#{indexed_base}:Z#{z} = 0"
      @emitter.dedent
      @emitter.line "NEXT"
    end

    # --- 命令ごとの下ごしらえ ---

    # **要りません。** アドレスは Z に組み立てるので、命令ごとに
    # 用意しておくものがありません。
    def prepare_instruction = nil


    # --- 値スロット ---

    # レジスタ窓の index_expr 番目のスロット
    #
    # **呼ぶ側は「何番目のレジスタか」だけを言います。** ワード数を掛けて
    # 基点を足すのは KV がアドレスを作る手順で、MELSEC は添字で直接指します。
    def reg_slot(key, index_expr, z: nil)
      slot_ref(key, index_expr, reg_offset, z: z)
    end

    # 定数プールの index_expr 番目。**固定領域 (FM) にあります**
    def pool_slot(key, index_expr, z: nil)
      slot_ref(key, index_expr, pool_offset, z: z, device: layout.fixed_device_name)
    end

    # 別のフレームのレジスタ
    #
    # **base_expr はブロック先頭からの語数**です。デバイスを絶対アドレスで
    # 指すので、ここでブロック先頭を足します。足す側を機種に任せているのは、
    # 型付きラベルの配列は先頭からの添字で指すためです。
    def frame_slot(key, index_expr, base_expr, z: nil)
      slot_ref(key, index_expr, "#{base_expr} + Z#{Z_INSTANCE}", z: z)
    end

    # 既に Z に載っている先頭アドレスを値スロットとして扱う
    #
    # 呼ぶ側が FOR の中などで自分で載せた場合に使います。**KV の作り方に
    # 踏み込む口**なので、MELSEC ではこれを使う経路そのものが変わります。
    def slot_on(z) = build_slot(z, layout.device_name)

    # 命令 1 つを出し終えたら忘れる。次の命令では Z を組み直す
    def forget_slots = @slot_cache.clear

    # --- バイトコード ---

    # 現在位置を読み、PC を 1 つ進める
    #
    # 固定領域はインデックス修飾でしか指せないので、アドレスを Z に載せてから
    # 読みます。MELSEC は `VMBC[VMPC]` の 1 文で済みます。
    def read_bytecode_into(dest)
      pc = state(layout.pc_addr)
      @emitter.line "Z1 = #{pc} + #{bytecode_offset}"
      @emitter.line "#{dest} = #{fixed_indexed_base}:Z1"
      @emitter.line "#{pc} = #{pc} + 1"
    end

    # 次の 1 バイトを覗く。**PC は進めません**
    #
    # 命令の取り込みで前置きを実行する命令 (`OP_SSEND`) が使います。枝の中で
    # もう一度読み直すので、ここで進めると 1 バイトずれます。
    def peek_bytecode_into(dest)
      @emitter.line "Z1 = #{state(layout.pc_addr)} + #{bytecode_offset}"
      @emitter.line "#{dest} = #{fixed_indexed_base}:Z1"
    end

    private

    # スロットの先頭アドレスを Z に載せ、その Z を指す Slot を返す
    #
    # **同じスロットを 2 度指すときは行を出しません** (key で覚えます)。
    # 命令 1 つの中で R[a] を何度も触るため、毎回 Z を組み直すと無駄が出ます。
    def slot_ref(key, index_expr, base_expr, z: nil, device: layout.device_name)
      return @slot_cache[key] if @slot_cache.key?(key)

      z ||= key == [:reg, :a] ? Z_PRIMARY : Z_SECONDARY
      @emitter.line "Z#{z} = #{words_of(index_expr)} + #{base_expr}"
      @slot_cache[key] = build_slot(z, device)
    end

    # 添字をワード単位に直す
    #
    # **足し算を含む添字は括弧で囲みます。** `a + 1 * 4` は `a + 4` になって
    # しまい、隣ではなく 4 つ先のスロットを指します。
    #
    # 0 番目は掛けても 0 なので、掛け算そのものを出しません。
    def words_of(index_expr)
      return "0" if index_expr == "0"

      expr = index_expr.include?(" ") ? "(#{index_expr})" : index_expr
      "#{expr} * #{VmConstants::SLOT_WORDS}"
    end

    # Z 1 本でタグと値の両方を指す。**型サフィックスはデバイス側**に付ける
    def build_slot(z, device)
      value = VmConstants::SLOT_VALUE_OFFSET
      Slot.new("#{device}#{VmConstants::SLOT_TYPE_OFFSET}:Z#{z}",
               "#{device}#{value}.L:Z#{z}",
               "#{device}#{value}.F:Z#{z}",
               ->(offset) { "#{device}#{value + offset}:Z#{z}" })
    end

  end

  # MELSEC Q (GX Works2 の ST) のデバイスの指し方
  #
  # **デバイスに割り付けた型付きラベルで指します。** 生のワードデバイスを素の
  # 式で足すと 16 ビットで計算され、**エラーにならないまま答えだけ狂います**
  # (実機で確認済み、doc/melsec.md)。ラベルなら型があるので起きません。
  #
  # ## 構造体がスロットと一致する
  #
  # faRuby のスロットは 4 ワード (タグ 1 + 値 2 + 予備 1)。MELSEC の構造体は
  # 詰め物が入らず 4 ワードちょうどなので、そのまま重なります (実機で確認済み)。
  #
  #   TYPE VMSLOT : STRUCT SLTAG : INT; SLNUM : DINT; SLPAD : INT; END_STRUCT
  #
  #   KV      Z1 := D7:Z9 * 4 + D32:Z9 + Z9;
  #           D1.L:Z1 := D1.L:Z2;
  #   MELSEC  VMREG[VMOPA].SLNUM := VMREG[VMOPB].SLNUM;
  #
  # **添字がレジスタ番号そのもの**なので、アドレス計算が要りません。値を実数
  # として読むときは、同じアドレスに重ねた REAL 版の構造体を使います。
  #
  # ## 名前の付け方
  #
  # **デバイス名に見える名前も予約語も使えません** (`BC` は B デバイスの 0x0C、
  # `VAL` は予約語)。ラベルは `VM`、構造体のメンバは `SL` を頭に付けます。
  class MelsecDevices
    include VmConstants

    include SavesIndexRegisters

    # VM 状態のラベルは MemoryLayout の OFFSET_* から名前を作ります。
    # **配置とラベルが 1 つの出どころから出る**ので、ずれません
    STATE_PREFIX = "VM"

    # 可変領域にかぶせる構造体配列
    #
    # **スロットはすべて 4 ワード境界にあります。** レジスタも汎用グローバル変数も
    # 配列プールも、同じ領域の別の場所というだけなので、1 本でまとめて指せます。
    # ワードオフセットを 4 で割れば添字になります。
    SLOT   = "VMSLOT"    # 可変領域の値スロット (タグ + 32 ビット値)
    SLOTF  = "VMSLOTF"   # 同じ場所を実数で
    # 固定領域にも同じ形をかぶせます。定数プールがスロットの並びだからです
    FIXED_SLOT  = "VMFSLOT"
    FIXED_SLOTF = "VMFSLOTF"
    # 値を 16 ビット 2 つとして見る形。デバイス参照が種別・幅・アドレスを
    # 2 ワードに詰めるので、そこだけこちらで触ります
    SLOTW  = "VMSLOTW"

    # スロットの型名。**ラベル名と別にします。** GX Works2 は型の欄に
    # 構造体名を書くので、同じ名前だと読む人がどちらか分かりません
    SLOT_TYPE       = "VMSLOTT"
    SLOT_FLOAT_TYPE = "VMSLOTFT"
    SLOT_WORD_TYPE  = "VMSLOTWT"

    # 詰め物。**faRuby のスロットは 4 ワードです** (タグ 1 + 値 2 + 予備 1)。
    # 三菱の構造体は詰め物が入らないので、この 1 語で 4 に揃えます
    PAD = "SLPAD"
    WORDS  = %w[SLW0 SLW1].freeze
    TAG    = "SLTAG"
    NUM    = "SLNUM"

    # 固定領域 (ZR) を 16 ビットで読む配列。バイトコードと表
    FIXED_WORD = "VMCODE"

    # 固定領域のデバイス。**ZR にバンクはありません**
    #
    # 名前は配置が持ちます (`memory.fixed_device`)。ホストから見た名前も
    # 同じなので、スクリプトとホストでアドレスが食い違いません。
    def fixed_device = layout.fixed_device_name

    # インデックスレジスタの退避先 (VM 状態の中に 9 語)
    Z_SAVE = "VMZSAVE"

    attr_reader :layout

    def initialize(layout, emitter = nil, labels = {})
      @layout = layout
      @emitter = emitter
      @labels = labels
      register_arrays
    end

    # 配ったラベルの定義。**生成コードと 1 つの出どころから出ます**
    #
    # 手で作ると必ずずれるので、指した先をそのまま定義として書き出します。
    attr_reader :labels

    Label = Struct.new(:name, :type, :device, :comment)

    # --- VM 状態 ---
    #
    # 16 ビットも 32 ビットも同じラベルです。**型はラベル定義が持ちます。**
    # KV は `.L` の付け外しで幅を選びましたが、こちらは型付きなので要りません。

    def state(addr) = state_label(addr)

    # **32 ビットは別のラベルです。** 同じ 2 ワードを INT と DINT の両方で
    # 触る場所があり (`TEMP32` を下位ワードだけ書く経路)、ラベルは型が
    # 固定なので名前を分けます。重ねて割り付けます。
    def state_long(addr) = state_label(addr, long: true)

    # **実数もまた別のラベルです。** 同じ 2 ワードを DINT と REAL の両方で
    # 触るため、型が固定なラベルでは名前を分けるしかありません
    def state_float(addr) = state_label(addr, float: true)

    # OFFSET_PC なら VMPC。定数名から作るので配置と食い違いません
    #
    # 名前の無いオフセットには通し番号を振ります。32 ビットの場所の上位ワード
    # (`TEMP32` の +1 など) や、見出しコメントが一覧を並べるときに通ります。
    def state_label(addr, long: false, float: false)
      offset = layout.offset_of(addr)
      suffix, type = if float then ["F", "単精度実数"]
                     elsif long then ["L", "ダブルワード[符号付き]"]
                     else ["", "ワード[符号付き]"]
                     end
      name = "#{STATE_PREFIX}#{self.class.state_names[offset] || "W#{offset}"}#{suffix}"
      remember(name, type, "#{layout.device_name}#{addr}", "VM 状態 +#{offset}")
      name
    end

    # オフセット => 名前 (OFFSET_PC なら PC)
    #
    # **32 ビットの置き場は上位ワードにも名前を付けます。** 上位だけを
    # 16 ビットで書く経路があり、`VMW17` では何のことか分からないためです。
    def self.state_names
      @state_names ||= begin
        named = MemoryLayout.constants.grep(/\AOFFSET_/).to_h do |const|
          [MemoryLayout.const_get(const), const.to_s.sub("OFFSET_", "").delete("_")]
        end
        named.to_a.each_with_object(named.dup) do |(offset, name), all|
          all[offset + 1] ||= "#{name}HI" if name.include?("TEMP32")
        end
      end
    end

    # --- Z に載せたアドレスで 1 ワードを指す ---
    #
    # **区切り記号が KV と違います** (`EM0:Z3` に対して `D0Z3`)。Z を算法の
    # 一時変数として使うところは KV と同じままです。
    def word_at(z, offset = 0)  = "#{layout.device_name}#{offset}Z#{z}"
    def fixed_at(z, offset = 0) = "#{fixed_device}#{offset}Z#{z}"

    # --- 実行中の irep の領域 ---

    def bytecode_offset   = state(layout.cur_bytecode_addr)
    def pool_offset       = state(layout.cur_pool_addr)
    def symbols_offset    = state(layout.cur_symbols_addr)
    def irep_table_offset = state(layout.irep_table_addr_addr)

    def fixed_offset(base) = "#{irep_table_offset} + #{layout.fixed_offset_of(base)}"

    # インデックス修飾の基点。KV と同じ形で使えます
    def indexed_base = "#{layout.device_name}0"
    def fixed_indexed_base = "#{fixed_device}0"

    # Z に組み立てる絶対アドレスの項
    #
    # **1 インスタンスなので定数です。** KV はブロック先頭を Z9 に載せて
    # 足しますが、こちらは場所が動きません。
    def block_offset(base) = base.to_s

    # レジスタ窓の先頭 (ワード単位の絶対アドレス)
    def reg_offset = "#{state(layout.reg_base_addr)} + #{layout.origin}"

    # --- インスタンスループ ---

    # **ラベルは固定のアドレスに割り付けます。** インスタンスごとに場所を
    # ずらす手が無いので、いまは 1 つだけです。増やすならラベルを機数ぶん
    # 用意することになります。
    def each_instance
      unless layout.instances == 1
        raise ArgumentError, "この機種は 1 インスタンスだけです (instances: #{layout.instances})"
      end

      yield
    end

    # レジスタファイルを 0 で埋める
    #
    # **型タグだけ潰せば足ります。** 0 は TT_EMPTY で、値は型が決まるまで
    # 読まれません。KV はワード単位で全部潰しますが、構造体ならメンバを
    # 名指しできます。
    def clear_register_file(_z)
      counter = state(layout.loop_counter_addr)
      first = layout.offset_of(layout.reg_file_base) / VmConstants::SLOT_WORDS
      @emitter.note "レジスタファイルクリア (型タグを TT_EMPTY に)"
      @emitter.line "FOR #{counter} = #{first} TO #{first + layout.max_regs - 1}"
      @emitter.indent
      @emitter.line "#{SLOT}[#{counter}].#{TAG} = 0"
      @emitter.dedent
      @emitter.line "NEXT"
    end

    # --- インデックスレジスタ ---

    # 退避先。VM 状態の中に 9 語並べた配列で持ちます
    #
    # **生成コードは Z を算法の一時変数に使います** (`Z3 = ...`)。ラダーと
    # 取り合う資源なので、KV と同じく退避して戻します。
    def z_save(z) = "#{Z_SAVE}[#{z - 1}]"

    # --- ラダーのデバイスを指す ---

    # 幅を指定して読む。**値の式を返します**
    #
    # **三菱に幅のサフィックスがありません。** 代わりの手が 2 つあります。
    #
    # ビットデバイスは桁指定が使えます (`K4M0Z6` で 16 個、`K8M0Z6` で 32 個)。
    # インデックス修飾と併用でき、1 文で読めます (実機で確認済み)。
    #
    # **ワードデバイスに 32 ビットの綴りはありません。** 16 ビット 2 回に開いて
    # スクラッチの重ね合わせに載せ、そこを指します。実数は同じ場所を REAL で
    # 読み替えるだけで、変換は入りません。
    def device_read(device, access, z)
      case access
      when ACCESS_L, ACCESS_D then long_read(device, z)
      when ACCESS_F then float_read(device, z)
      when ACCESS_U then unsigned_read(device, z)
      else word_ref(device, z)
      end
    end

    # 幅を指定して書く
    def device_write(device, access, z, source)
      case access
      when ACCESS_L, ACCESS_D then long_write(device, z, source)
      when ACCESS_F then float_write(device, z, source)
      else @emitter.line "#{word_ref(device, z)} = #{source.long}"
      end
    end

    # 個別ビット。**区切り記号が無いだけです** (`MR0:Z6` に対して `M0Z6`)
    def bit_ref(device, z) = "#{device.name}0Z#{z}"

    # 何もしない文
    #
    # **GX Works2 は文の無い分岐を通しません。** 注釈だけで閉じている分岐に
    # 1 つ置きます。
    #
    # 行き先は**振り分け用の写し**です。1 本にまとめた三菱では組ごとの関門が
    # 無く、この 1 語は誰も読みません。
    #
    # **自己代入は使いません。** ループの制御変数を使って弾かれたことがあり
    # (「1 番目の引数に不正な値」)、制御変数だからか自己代入だからかを
    # 確かめていません。定数を入れればどちらでもありません。
    def noop_statement = "#{state(layout.dispatch_addr)} = 0"

    # ワードデバイスから 1 ワードそのまま
    #
    # **中身を解釈しません。** 文字列のバイト列を運ぶだけなので、ビット列が
    # 保てれば符号は問いません。運び先の Z も 16 ビット符号付きです。
    def raw_word(device, z) = "#{device.name}0Z#{z}"

    # --- ビットをずらす・重ねる ---

    # 桁数だけずらす
    #
    # **`SHR` / `SHL` は使えません。** 桁数に定数しか置けず、faRuby は
    # 実行時に決まる桁数でずらします。掛け算・割り算に開きます。
    #
    # 桁数を 5 段に分けて、立っている桁のぶんだけ掛け (割り) ます。ループを
    # 回すより短く、**インデックスレジスタも余分なスクラッチも要りません**。
    # ここへ来る値は正で、桁数は 0-31 です (呼ぶ側が保証します)。
    #
    # **桁数は壊れます。** どの分岐でも読み終えた後なので構いません。
    def shift(target, amount, left:)
      SHIFT_STEPS.each do |bits|
        @emitter.if_("#{amount} >= #{bits}") do
          @emitter.line "#{target} = #{target} #{left ? "*" : "/"} #{1 << bits}"
          @emitter.line "#{amount} = #{amount} - #{bits}" unless bits == 1
        end
      end
    end

    # 5 段に分けた桁数。16 + 8 + 4 + 2 + 1 で 0-31 を表せます
    SHIFT_STEPS = [16, 8, 4, 2, 1].freeze

    # ビット演算
    #
    # **`AND` / `OR` / `XOR` はビット列型しか取りません。** 32 ビット整数は
    # そのまま渡せないので、ビット列に読み替えてから戻します。値は変わりません。
    def bit_op(target, lhs, operator, rhs)
      @emitter.line "#{target} = DWORD_TO_DINT(#{as_bits(lhs)} #{operator} #{as_bits(rhs)})"
    end

    # **`DWORD#1` とは書けません。** `D#` を時間の定数と読まれます。
    # 数も変換に通します
    def as_bits(expr) = "DINT_TO_DWORD(#{expr})"

    # --- Z に載せたアドレスの 32 ビット ---

    # 読む。**16 ビット 2 回に開いてスクラッチへ載せ、そこを指します**
    #
    # ラベルは型が固定なので、任意のアドレスを 32 ビットで指す綴りが
    # ありません。重ね合わせを持っているスクラッチを経由します。
    def long_at(z, offset, scratch)
      @emitter.line "#{state(scratch)} = #{word_at(z, offset)}"
      @emitter.line "#{state(scratch + 1)} = #{word_at(z, offset + 1)}"
      state_long(scratch)
    end

    def write_long_at(z, offset, source)
      @emitter.line "#{word_at(z, offset)} = #{source.lo}"
      @emitter.line "#{word_at(z, offset + 1)} = #{source.hi}"
    end

    # --- 符号拡張 ---

    # 16 ビットオペランドを符号付きとして読み直す
    #
    # **何もしません。** ラベルが符号付き INT で、取り込みの `Z3 * 256 + Z4`
    # が 2 の補数で回り込むため、その時点ですでに符号付きの値です。KV のように
    # 65536 を引くと、比較の 32768 も引く数も符号付き INT に入りません。
    def normalize_signed16(var) = nil

    # bits ビットの値を符号拡張して 32 ビットスクラッチに置く
    #
    # **ラベルに型があるので変換 1 文です。** オペランドは符号付き INT で、
    # 取り込みの `Z3 * 256 + Z4` が 2 の補数で回り込むため、その時点で
    # すでに符号付きの値になっています。あとは幅を広げるだけです。
    #
    # KV のように上位ワードを 65535 で埋める手は使えません。符号付き INT に
    # 入らないためです。
    def sign_extend(value, bits)
      raise ArgumentError, "16 ビット未満は符号付き INT に収まりません (#{bits})" if bits < 16

      @emitter.line "#{@emitter.scratch32} = #{value}"
    end

    # 符号を反転した値。**型があるので 1 文です**
    #
    # KV は 16 ビットを 2 つ並べて 32 ビットを組み立てますが、こちらは
    # そのまま書けます。オペランドは INT なので変換を挟みます。
    def negate(value) = "0 - #{value}"

    # --- 命令ごとの下ごしらえ ---

    # レジスタ窓の先頭をスロット単位に直しておく
    #
    # **添字はスロット番号なので、ワード単位の REG_BASE を 4 で割ります。**
    # レジスタを触るたびに割ると嵩むため、命令の取り込みで 1 回だけ割って
    # 置いておきます。呼び出しフレームで窓が動いても、次の命令で作り直されます。
    def prepare_instruction
      @emitter.note "レジスタ窓の先頭をスロット単位に直す (添字に使う)"
      @emitter.line "#{state(layout.reg_slot_base_addr)} = " \
                    "#{state(layout.reg_base_addr)} / #{VmConstants::SLOT_WORDS}"
    end

    # --- 値スロット ---
    #
    # **行を出しません。** KV はアドレスを Z に載せる文が要りましたが、
    # 構造体の添字はそのまま書けます。

    def reg_slot(_key, index_expr, z: nil)
      slot_at("#{state(layout.reg_slot_base_addr)} + #{index_expr}")
    end

    # 定数プールは固定領域にあります。**同じ形の配列をかぶせて添字で指します**
    #
    # プールの先頭はワード単位なので 4 で割って添字にします。irep ごとに
    # 位置が違うため、割り算は実行時になります。
    def pool_slot(_key, index_expr, z: nil)
      base = "(#{pool_offset}) / #{VmConstants::SLOT_WORDS}"
      slot_at("#{base} + #{index_expr}", FIXED_SLOT, FIXED_SLOTF)
    end

    # 別のフレームのレジスタ
    #
    # **base_expr はブロック先頭からの語数**なので、そのまま添字に直せます。
    # 配列がブロックの先頭に割り付けてあるためです (KV は絶対アドレスを作ります)。
    def frame_slot(_key, index_expr, base_expr, z: nil)
      slot_at("(#{base_expr}) / #{VmConstants::SLOT_WORDS} + #{index_expr}")
    end

    # Z に載せたワードアドレスをスロットとして扱う
    #
    # **4 で割って添字にします。** シンボル表が持っているのはワードアドレス
    # なので、汎用グローバル変数の経路がここを通ります。
    # Z に載せた**絶対アドレス**のスロット
    #
    # **配列はブロックの先頭から始まります。** Z が持つのは絶対アドレスなので、
    # 先頭を引いてから添字に直します。KV はデバイスを絶対アドレスで指すので
    # 引く必要がありませんでした。
    def slot_on(z)
      slot_at("(Z#{z} - #{layout.origin}) / #{VmConstants::SLOT_WORDS}")
    end

    # 覚えておく必要がありません (行を出さないため)
    def forget_slots = nil

    # --- バイトコード ---

    # 現在位置を読み、PC を 1 つ進める。**1 文で済みます**
    def read_bytecode_into(dest)
      pc = state(layout.pc_addr)
      @emitter.line "#{dest} = #{FIXED_WORD}[#{pc} + #{bytecode_offset}]"
      @emitter.line "#{pc} = #{pc} + 1"
    end

    # 次の 1 バイトを覗く。**PC は進めません**
    def peek_bytecode_into(dest)
      @emitter.line "#{dest} = #{FIXED_WORD}[#{state(layout.pc_addr)} + #{bytecode_offset}]"
    end

    # --- 書き出し ---

    # グローバルラベルの一覧。GX Works2 に貼り付けられる形です
    #
    # **手で作ると必ずずれます。** 生成コードが指したラベルをそのまま
    # 覚えてあるので、その一覧を出します。使っていないラベルは出ません。
    #
    # 列は 区分・名前・型・(空)・デバイス・IEC アドレス と、後ろに空欄 5 つ
    # です。**11 列で 1 行**で、GX Works2 が書き出す形と同じにしてあります。
    def label_table
      rows = labels.values.sort_by { |label| [label.device[0], sort_key(label.device), label.name] }
      rows.map { |label|
        device, address = label_device(label)
        (["VAR_GLOBAL", label.name, label.type, "", device, address] + [""] * 5).join("\t")
      }.join("\n") + "\n"
    end

    # 構造体の配列は先頭デバイスを表に書けません
    #
    # **GX Works2 が「詳細設定」の別画面で持ちます。** 表には押しボタンが
    # 出るだけなので、貼り付けでは渡せません。5 つだけ手で設定します。
    DETAIL = "詳細設定"

    def structure_label?(label) = label.type.start_with?(STATE_PREFIX)

    # 先頭デバイスを手で設定するラベル。名前 => デバイス
    def structure_labels
      labels.values.select { |l| structure_label?(l) }
            .sort_by { |l| [l.device[0], sort_key(l.device), l.name] }
            .map { |l| [l.name, l.device] }
    end

    # 構造体の定義。ラベルより先にこちらを登録します
    #
    # **同じ 4 ワードを 3 通りに見ます。** 値が 32 ビット整数か実数か、
    # 16 ビット 2 つかは実行時にしか決まらないためです。重ねて割り付けます。
    def structure_definitions
      [[SLOT_TYPE,       [[TAG, "ワード[符号付き]"], [NUM, "ダブルワード[符号付き]"], [PAD, "ワード[符号付き]"]]],
       [SLOT_FLOAT_TYPE, [[TAG, "ワード[符号付き]"], [NUM, "単精度実数"], [PAD, "ワード[符号付き]"]]],
       [SLOT_WORD_TYPE,  [[TAG, "ワード[符号付き]"], [WORDS[0], "ワード[符号付き]"],
                          [WORDS[1], "ワード[符号付き]"], [PAD, "ワード[符号付き]"]]]]
    end

    private

    # 16 ビットで指す
    #
    # ビットデバイスは桁指定で 16 個まとめて (`K4M0Z6`)、ワードデバイスは
    # そのまま (`D0Z6`)。どちらも INT です。
    def word_ref(device, z, offset = 0)
      return "K4#{device.name}0Z#{z}" if device.bit?

      "#{device.name}#{offset}Z#{z}"
    end

    # 32 ビットで読む
    #
    # ビットデバイスは桁指定 1 文で済みます。ワードデバイスは 16 ビット
    # 2 回に開いて重ね合わせに載せます。
    def long_read(device, z)
      return "K8#{device.name}0Z#{z}" if device.bit?

      @emitter.line "#{@emitter.scratch_lo} = #{word_ref(device, z, 0)}"
      @emitter.line "#{@emitter.scratch_hi} = #{word_ref(device, z, 1)}"
      @emitter.scratch32
    end

    # 実数として読む
    #
    # **変換ではなくビット列の読み替えです。** 同じ 2 ワードを REAL の
    # ラベルで読みます。
    def float_read(device, z)
      if device.bit?
        @emitter.line "#{@emitter.scratch32} = K8#{device.name}0Z#{z}"
      else
        @emitter.line "#{@emitter.scratch_lo} = #{word_ref(device, z, 0)}"
        @emitter.line "#{@emitter.scratch_hi} = #{word_ref(device, z, 1)}"
      end
      state_float(layout.temp32_addr)
    end

    # 16 ビット符号なしとして読む
    #
    # **INT は符号付きなので、負なら 65536 を足して 32 ビットに広げます。**
    # KV の EM はデバイスが符号なしだったので、そのまま読めていました。
    def unsigned_read(device, z)
      value = @emitter.scratch32
      @emitter.line "#{value} = #{word_ref(device, z)}"
      @emitter.if_("#{value} < 0") { @emitter.line "#{value} = #{value} + 65536" }
      value
    end

    def long_write(device, z, source)
      return @emitter.line("K8#{device.name}0Z#{z} = #{source.long}") if device.bit?

      @emitter.line "#{word_ref(device, z, 0)} = #{source.lo}"
      @emitter.line "#{word_ref(device, z, 1)} = #{source.hi}"
    end

    # 実数を書く。**読むときと同じくビット列をそのまま移します**
    def float_write(device, z, source) = long_write(device, z, source)


    # 並び順。デバイス番号で並べると割り付けが読めます
    def sort_key(device) = device[/\d+/].to_i

    # デバイスと IEC アドレスの欄
    #
    # 16 ビットは `%MW`、32 ビットと実数は `%MD`。**領域番号は D が 0、
    # ZR が 12** です (実機で確認済み)。
    def label_device(label)
      return [DETAIL, DETAIL] if structure_label?(label)

      area = label.device.start_with?(fixed_device) ? 12 : 0
      width = label.type.start_with?("ワード") ? "W" : "D"
      [label.device, "%M#{width}#{area}.#{label.device[/\d+/]}"]
    end

    # 同じ名前を 2 度覚えない。指すたびに呼ばれます

    def remember(name, type, device, comment)
      @labels[name] ||= Label.new(name, type, device, comment)
      name
    end

    # いつも要る配列を先に覚えておく
    #
    # **構造体は 3 通りに重ねます。** 値を 32 ビット・実数・16 ビット 2 つの
    # どれで読むかが実行時に決まるためです。faRuby のスロットは 4 ワード
    # (タグ 1 + 値 2 + 予備 1) で、MELSEC の構造体は詰め物が入りません。
    def register_arrays
      slots = layout.instance_size / VmConstants::SLOT_WORDS
      fixed_slots = layout.fixed_instance_size / VmConstants::SLOT_WORDS
      variable = "#{layout.device_name}#{layout.origin}"
      fixed = "#{fixed_device}#{layout.fixed_origin}"

      remember(SLOT,  "#{SLOT_TYPE}(0..#{slots - 1})",  variable, "値スロット")
      remember(SLOTF, "#{SLOT_FLOAT_TYPE}(0..#{slots - 1})", variable, "同じ場所を実数で")
      remember(SLOTW, "#{SLOT_WORD_TYPE}(0..#{slots - 1})", variable, "同じ場所を 16 ビット 2 つで")
      remember(FIXED_SLOT,  "#{SLOT_TYPE}(0..#{fixed_slots - 1})",  fixed, "定数プール")
      remember(FIXED_SLOTF, "#{SLOT_FLOAT_TYPE}(0..#{fixed_slots - 1})", fixed, "同じ場所を実数で")
      remember(FIXED_WORD, "ワード[符号付き](0..#{layout.fixed_instance_size - 1})", fixed,
               "バイトコードと表")
      remember(Z_SAVE, "ワード[符号付き](0..8)",
               "#{layout.device_name}#{layout.z_save_addr(1)}", "Z の退避先")
      noop_statement
    end

    def slot_at(index_expr, array = SLOT, float_array = SLOTF)

      KvDevices::Slot.new("#{array}[#{index_expr}].#{TAG}",
                          "#{array}[#{index_expr}].#{NUM}",
                          "#{float_array}[#{index_expr}].#{NUM}",
                          ->(offset) { word_of(index_expr, offset) })
    end

    # 値ワードを 16 ビット単位で指す
    #
    # **構造体のメンバの一部だけを取り出す綴りがありません。** そこで、値を
    # 16 ビット 2 つとして見る形を同じアドレスに重ねてあります。デバイス参照が
    # 種別・幅・アドレスを 2 ワードに詰めるので、そこで通ります。
    def word_of(index_expr, offset)
      name = WORDS[offset] or
        raise ArgumentError, "値ワードは 2 つまでです (offset: #{offset})"

      "#{SLOTW}[#{index_expr}].#{name}"
    end
  end
end
