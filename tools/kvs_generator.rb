# frozen_string_literal: true

# KV スクリプト生成器
#
# tools/opcode_table.rb の定義から plc/keyence/vm_core.kvs を生成します。
# 再生成は `rake vm_core`。
#
# KvsEmitter は「記号バックエンド」です。命令定義の body を実行すると、
# 値の代わりに KV スクリプトの式文字列を返し、副作用としてコード行を出力します。
# 同じ body を SimVm (simulator/sim_vm.rb) に渡すと実際に計算が行われます。
#
# デバイス構文のイディオムはすべてこのファイルに集約されています。
# 「型サフィックスはデバイス側に付ける (EM0.L:Z1)」という規則も
# ここだけで守れば全命令に反映されます。

require_relative "vm_constants"
require_relative "memory_layout"
require_relative "opcode_table"

module FaRuby
  class KvsEmitter
    include VmConstants

    INDENT = "    "

    # オペランドの並び (格納先アドレスは配置から決まる)
    OPERAND_NAMES = %i[a b c].freeze

    # インデックスレジスタの割り当て
    # Z1 = 主オペランド (通常は代入先の R[a])、Z2 = 副オペランド
    # Z3-Z8 はバイトコードフェッチとデバイステーブル参照が使う
    # Z9 = 実行中インスタンスのブロック先頭
    Z_PRIMARY = 1
    Z_SECONDARY = 2
    Z_INSTANCE = 9
    # OP_SETIDX の代入元。Z1 は参照、Z2 は添字が使うので3本目を割り当てる
    Z_VALUE = 3

    # faRuby が書き換える Z レジスタ
    #
    # PLC の Z はラダーと共有する資源なので、スクリプトの先頭で退避し
    # 末尾で復元する。ここに挙げたものだけを使うことを
    # test_kvs_generator.rb が検証する。
    #
    # Z11 / Z12 は特別な用途があり使用できない (実機で確認済み)。
    # 使えるのは Z1-Z10 で、faRuby は Z1-Z9 を使う。Z10 は未使用。
    USED_Z = (1..9).to_a.freeze

    # ワードデバイス (アクセス幅の選択が必要)
    WORD_DEVICES = [[DEVICE_TYPE_EM, "EM"], [DEVICE_TYPE_DM, "DM"], [DEVICE_TYPE_ZF, "ZF"]].freeze

    # ビットデバイス。set_res が true のものは代入ではなく SET/RES を使う
    BIT_DEVICES = [
      [DEVICE_TYPE_R,  "R",  false], [DEVICE_TYPE_MR, "MR", false],
      [DEVICE_TYPE_B,  "B",  false], [DEVICE_TYPE_L,  "LR", false],
      [DEVICE_TYPE_T,  "T",  true],  [DEVICE_TYPE_C,  "C",  true],
    ].freeze

    # アクセス幅の分岐順。最後 (.S) が ELSE になる
    ACCESS_BRANCHES = [[ACCESS_L, "L"], [ACCESS_U, "U"], [ACCESS_D, "D"], [ACCESS_F, "F"]].freeze
    ACCESS_DEFAULT_SUFFIX = "S"

    # タイマ・カウンタは .F を受け付けない (KV Studio の変換が通らない)。
    # 幅を付けると現在値を返すデバイスなので、実数の出番が無い。
    NO_FLOAT_DEVICES = [DEVICE_TYPE_T, DEVICE_TYPE_C].freeze

    # KV スクリプトの比較演算子
    COMPARISON = { eq: "=", ne: "<>", lt: "<", le: "<=", gt: ">", ge: ">=" }.freeze
    ARITHMETIC = { add: "+", sub: "-", mul: "*", div: "/" }.freeze

    attr_reader :lines, :layout

    def initialize(level: 0, layout: MemoryLayout.default)
      @lines = []
      @level = level
      @layout = layout
      @slot_cache = {}
    end

    # インデックス修飾の基点 (例: "EM0")
    # PC を指す layout.pc_addr とは別物なので混同しないこと。
    # デバイス番号 0 からの相対を Z レジスタで指定する書き方に使う。
    def indexed_base = "#{layout.device_name}0"

    # 固定領域 (FM) をインデックス修飾で指すときの基点
    #
    # FM は ZF をバンクに分けたもの。スクリプトの先頭で FRSET でバンクを
    # 選んであるため、ここではバンクを意識せず 0-32767 のアドレスで指せる。
    def fixed_indexed_base = "#{layout.fixed_device_name}0"

    # --- インスタンス相対のデバイス参照 ---
    #
    # ブロック先頭は Z9 に載っている。ブロック内の固定位置はオフセットを
    # インデックス修飾で足して指す (EM7:Z9)。こうすることで、どのインスタンス
    # でも同じコードが動く。
    #
    # 型サフィックスはデバイス側に付ける (EM16.L:Z9)。EM16:Z9.L と書くと
    # .L がインデックスレジスタに結合し、16ビットアクセスに退化する。

    # ブロック内の固定位置を指す (16ビット)
    def state(addr) = "#{layout.device_name}#{layout.offset_of(addr)}:Z#{Z_INSTANCE}"

    # ブロック内の固定位置を指す (32ビット)
    def state_long(addr) = "#{layout.device_name}#{layout.offset_of(addr)}.L:Z#{Z_INSTANCE}"

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
    def bytecode_offset  = state(layout.cur_bytecode_addr)
    def pool_offset      = state(layout.cur_pool_addr)
    def symbols_offset   = state(layout.cur_symbols_addr)
    def irep_table_offset = state(layout.irep_table_addr_addr)

    # 固定領域の位置。インスタンスごとに違うため先頭からの相対で組み立てる
    def fixed_offset(base) = "#{irep_table_offset} + #{layout.fixed_offset_of(base)}"

    def reg_offset = "#{state(layout.reg_base_addr)} + Z#{Z_INSTANCE}"

    # --- インスタンスループ ---

    # 実行するインスタンスを順に巡る
    #
    # ブロック先頭そのものをループ変数にすることで、インスタンス番号を
    # 別に持たずに済む。instances が 1 でも同じ形にして経路を1本に保つ。
    def each_instance
      note "インスタンスごとの実行 (ブロック先頭を Z#{Z_INSTANCE} に載せる)"
      note "instances = #{layout.instances}"
      line "FOR Z#{Z_INSTANCE} = #{layout.base} TO #{layout.last_origin} " \
           "STEP #{layout.instance_size}"
      indent
      yield
      dedent
      line "NEXT"
    end

    # --- Z レジスタの退避・復元 ---
    #
    # インスタンスループの外側で1回だけ行うため、退避先は絶対アドレスで指す。

    # 使用する Z レジスタをメモリへ退避する
    def save_z_registers
      note "インデックスレジスタの退避"
      note "Z はラダーと共有する資源のため、faRuby の実行前後で"
      note "内容が変わらないようにする (1スキャンにつき1回)"
      USED_Z.each { |z| line "#{layout.device(layout.z_save_addr(z))} = Z#{z}" }
    end

    # 退避した Z レジスタを復元する
    def restore_z_registers
      note "インデックスレジスタの復元"
      USED_Z.each { |z| line "Z#{z} = #{layout.device(layout.z_save_addr(z))}" }
    end

    # --- ファイルレジスタのバンク ---
    #
    # 固定領域は FM (ZF をバンクに分けたもの) に置いてあります。触る前に
    # FRSET でバンクを選び、抜けるときに 0 に戻します。
    #
    # **現在のバンクを読む命令が無いため、Z のように退避して戻せません。**
    # ラダーが 0 以外のバンクを使っていると壊すことになります。

    def select_fixed_bank
      note "固定領域 (#{layout.fixed_device_name}) のバンクを選ぶ"
      note "現在のバンクを読む命令が無いため、抜けるときは 0 に戻す"
      line "FRSET(#{MemoryLayout::FIXED_BANK})"
    end

    def restore_fixed_bank
      note "ファイルレジスタのバンクを 0 に戻す"
      line "FRSET(0)"
    end

    # --- 行の組み立て ---

    def line(text)
      @lines << (INDENT * @level + text)
    end

    def blank
      @lines << ""
    end

    def note(text)
      line(text.empty? ? "'" : "' #{text}")
    end
    alias comment note

    def indent = @level += 1
    def dedent = @level -= 1

    # 命令ごとにインデックスレジスタの割り当てをリセットする
    def begin_instruction
      @slot_cache = {}
    end

    # IF cond THEN <block> END IF
    def if_(cond)
      line "IF #{cond} THEN"
      indent
      yield
      dedent
      line "END IF"
    end
    alias if_block if_

    # IF cond THEN <block> ELSE ... 呼び出し側が ELSE 本体を出し end_block で閉じる
    def if_else_block(cond)
      line "IF #{cond} THEN"
      indent
      yield
      dedent
      line "ELSE"
      indent
    end

    def end_block
      dedent
      line "END IF"
    end

    # --- 値 (KV スクリプトの式文字列を返す) ---

    # オペランド a / b / c の格納先デバイス
    def operand(name)
      index = OPERAND_NAMES.index(name) or raise ArgumentError, "不明なオペランド: #{name}"

      state(layout.operand_a_addr + index)
    end

    def const(n) = n.to_s

    # 値スロットへの参照。1本の Z でタグと値の両方を指す
    #
    # 値は 32ビット整数 (.L) としても単精度実数 (.F) としても読めます。
    # どちらで読むかは実行時のタグで決まるため、生成コードは両方の書き方を
    # 出しておいて IF で選びます。
    Slot = Struct.new(:tag, :z, :device_name) do
      def ref(suffix) = "#{device_name}#{SLOT_VALUE_OFFSET}.#{suffix}:Z#{z}"

      def value = ref("L")   # 32ビット符号付き整数
      def float = ref("F")   # 単精度実数

      # 値ワードを16ビット単位で指す (IEEE754 のビット列を直接書くときに使う)
      def word(offset) = "#{device_name}#{SLOT_VALUE_OFFSET + offset}:Z#{z}"
    end

    def reg_slot(name)      = slot_ref([:reg, name], "#{operand(name)} * #{SLOT_WORDS}", reg_offset)
    def reg_next_slot(name) = slot_ref([:reg_next, name], "(#{operand(name)} + 1) * #{SLOT_WORDS}", reg_offset)
    # 定数プールは固定領域 (FM) にある
    def pool_slot(name)
      slot_ref([:pool, name], "#{operand(name)} * #{SLOT_WORDS}", pool_offset,
               device: layout.fixed_device_name)
    end

    def reg(name)      = reg_slot(name).value
    def reg_next(name) = reg_next_slot(name).value
    def pool(name)     = pool_slot(name).value

    def reg_tag(name)      = reg_slot(name).tag
    def reg_next_tag(name) = reg_next_slot(name).tag

    def binop(op, lhs, rhs) = "#{lhs} #{ARITHMETIC.fetch(op)} #{rhs}"
    def cmp(op, lhs, rhs)   = "#{lhs} #{COMPARISON.fetch(op)} #{rhs}"

    # 符号拡張して32ビットスクラッチに置く
    def sign_extend(value, bits)
      note "#{bits}ビット値を符号拡張して32ビットスクラッチに置く"
      note "16ビット符号なしのまま引き算すると桁が壊れるため" if bits < 16
      threshold = 1 << (bits - 1)
      line "#{scratch_lo} = #{value}"
      line "#{scratch_hi} = 0"
      if_("#{value} >= #{threshold}") do
        line "#{scratch_lo} = #{value} + #{0x1_0000 - (1 << bits)}" if bits < 16
        line "#{scratch_hi} = 65535"
      end
      scratch32
    end

    # 上位/下位ワードを並べて32ビット値にする
    def compose32(hi, lo)
      note "上位 * 65536 は16ビット演算になり桁上がりが落ちるため、"
      note "下位/上位ワードを並べて32ビットとして読む"
      line "#{scratch_lo} = #{lo}"
      line "#{scratch_hi} = #{hi}"
      scratch32
    end

    # 2の補数を32ビットで組み立てる
    def negate(value)
      note "2の補数を32ビットで組み立てる"
      line "#{scratch_lo} = 0 - #{value}"
      line "#{scratch_hi} = 0"
      if_("#{value} <> 0") { line "#{scratch_hi} = 65535" }
      scratch32
    end

    # --- 動作 ---

    # R[a] = 整数値
    def set_reg_int(name, value)
      dest = reg_slot(name)
      line "#{dest.value} = #{value}"
      line "#{dest.tag} = #{TT_INTEGER}"
    end

    # R[a] = nil / true / false / self
    #
    # 値ワードにも既定値を入れる。ビットデバイスへの書き込みが値だけで
    # 判定できるようにするため (true=1, false=nil=0)。
    def set_reg_special(name, tag)
      dest = reg_slot(name)
      line "#{dest.value} = #{TT_CANONICAL_VALUE.fetch(tag)}"
      line "#{dest.tag} = #{tag}"
    end

    # R[a] = R[b] (タグごと複製)
    def move_reg(dest_name, src_name)
      dest = reg_slot(dest_name)
      src = slot_ref([:reg_src, src_name], "#{operand(src_name)} * #{SLOT_WORDS}",
                     reg_offset, z: Z_SECONDARY)
      line "#{dest.value} = #{src.value}"
      line "#{dest.tag} = #{src.tag}"
    end

    # R[a] = Pool[b] (タグごと複製)
    def load_pool(dest_name, pool_name)
      dest = reg_slot(dest_name)
      src = pool_slot(pool_name)
      line "#{dest.value} = #{src.value}"
      line "#{dest.tag} = #{src.tag}"
    end

    # --- 数値演算の型振り分け ---
    #
    # KV スクリプトは整数と実数の混在を自動で昇格します (実機で確認済み)。
    # 2.5 + 3 は 5.5 になり、.F への代入は数値変換されます。したがって
    # faRuby がすることは「タグを見て .F と .L のどちらの書き方を出すか」
    # だけで、IEEE754 を手で組み立てる必要はありません。
    #
    # 整数どうしの経路を残すのは、32ビット整数が単精度の仮数 (24ビット) に
    # 収まらないためです。すべて実数にすると大きな整数の精度が落ちます。

    # 両オペランドの型で分岐し、実数が絡む場合と整数どうしで別の本体を出す
    #
    # rhs_tag が nil のオペランド (バイトコードの即値) は常に整数として扱う。
    def numeric_dispatch(lhs, rhs, rhs_tag: nil, &body)
      is_float = ->(tag) { "#{tag} = #{TT_FLOAT}" }

      if rhs_tag.nil?
        # 即値は整数固定。左辺の型だけで 2 分岐
        if_else_block(is_float.(lhs.tag)) { body.call(:float, lhs.float, rhs) }
        body.call(:integer, lhs.value, rhs)
        end_block
        return
      end

      if_else_block(is_float.(lhs.tag)) do
        if_else_block(is_float.(rhs_tag)) { body.call(:float, lhs.float, rhs.float) }
        body.call(:float, lhs.float, rhs.value)
        end_block
      end
      if_else_block(is_float.(rhs_tag)) { body.call(:float, lhs.value, rhs.float) }
      body.call(:integer, lhs.value, rhs.value)
      end_block
      end_block
    end

    # R[a] = R[a] + R[a+1]
    #
    # 文字列どうしなら連結します。**判定は整数どうしの枝の中**に置きます。
    # 足し算は最も多く通る経路なので、手前に比較を足すと全体が遅くなります。
    def set_reg_add(name, heap_code)
      dest = reg_slot(name)
      rhs = reg_next_slot(name)

      numeric_dispatch(dest, rhs, rhs_tag: rhs.tag) do |kind, l, r|
        if kind == :float
          line "#{dest.float} = #{binop(:add, l, r)}"
          line "#{dest.tag} = #{TT_FLOAT}"
        else
          if_else_block("#{dest.tag} = #{TT_STRING}") { add_strings(dest, rhs, heap_code) }
          line "#{dest.value} = #{binop(:add, l, r)}"
          line "#{dest.tag} = #{TT_INTEGER}"
          end_block
        end
      end
    end

    # R[a] = R[a] <op> R[a+1] / R[a] <op> 即値
    def set_reg_arith(name, op, immediate: nil)
      dest = reg_slot(name)
      rhs = immediate ? operand(immediate) : reg_next_slot(name)
      rhs_tag = immediate ? nil : reg_next_tag(name)

      numeric_dispatch(dest, rhs, rhs_tag: rhs_tag) do |kind, l, r|
        if kind == :float
          line "#{dest.float} = #{binop(op, l, r)}"
          line "#{dest.tag} = #{TT_FLOAT}"
        else
          line "#{dest.value} = #{binop(op, l, r)}"
          line "#{dest.tag} = #{TT_INTEGER}"
        end
      end
    end

    # R[a] = (R[a] <op> R[a+1]) ? true : false
    #
    # 数値は型が違っても値で比べる (Ruby では 1 < 1.5 も 1 == 1.0 も成り立つ)。
    def set_reg_cmp(name, op)
      dest = reg_slot(name)
      rhs = reg_next_slot(name)

      numeric_dispatch(dest, rhs, rhs_tag: reg_next_tag(name)) do |_kind, l, r|
        if_else_block(cmp(op, l, r)) { assign_bool(dest, true) }
        assign_bool(dest, false)
        end_block
      end
    end

    # R[a] = (lhs <op> rhs) ? true : false (型を見ない単純比較)
    def set_reg_bool(name, op, lhs, rhs)
      dest = reg_slot(name)
      if_else_block(cmp(op, lhs, rhs)) { assign_bool(dest, true) }
      assign_bool(dest, false)
      end_block
    end

    # R[a] = (R[a] == R[a+1]) ? true : false
    #
    # 型が違えば等しくない (Ruby では nil == false も 1 == true も偽)。
    # 値だけを比べると nil と false と 0 が同一になってしまう。
    def set_reg_eq(name)
      eq_into(reg_slot(name), reg_next_slot(name))
    end

    def eq_into(lhs, rhs, negate: false)
      note "数値は型が違っても値で比べる (Ruby では 1 == 1.0 は真)"
      note "数値以外は型と値の両方が一致したときだけ真 (nil == false は偽)"
      note "結果を R[a] に書くと比較元が壊れるため、先に判定してから代入する"
      line "#{scratch_lo} = 0"
      note "シンボルや配列のタグは #{TT_INTEGER} より大きいので、上限も見ないと"
      note "番号やスロット番号が数値として比べられてしまう"
      lhs_numeric = numeric_flag_into(3, lhs.tag)
      rhs_numeric = numeric_flag_into(4, rhs.tag)

      if_else_block(lhs_numeric) do
        if_else_block(rhs_numeric) do
          numeric_dispatch(lhs, rhs, rhs_tag: rhs.tag) do |_kind, l, r|
            if_(cmp(:eq, l, r)) { line "#{scratch_lo} = 1" }
          end
        end
        note "数値と非数値は等しくない"
        end_block
      end
      if_(cmp(:eq, lhs.tag, rhs.tag)) do
        if_else_block(cmp(:eq, lhs.tag, const(TT_STRING))) do
          compare_string_content(lhs.value, rhs.value)
          if_("#{str_flag} = 1") { line "#{scratch_lo} = 1" }
        end
        if_(cmp(:eq, lhs.value, rhs.value)) { line "#{scratch_lo} = 1" }
        end_block
      end
      end_block

      if_else_block("#{scratch_lo} = 1") { assign_bool(lhs, !negate) }
      assign_bool(lhs, negate)
      end_block
    end

    # R[a] = R[a] / R[a+1]
    #
    # 整数どうしは Ruby と同じ切り下げ。実数が絡めば実数除算。
    def set_reg_div(name, error_code)
      dest = reg_slot(name)
      rhs = reg_next_slot(name)

      numeric_dispatch(dest, rhs, rhs_tag: reg_next_tag(name)) do |kind, l, r|
        kind == :float ? float_div(dest, l, r) : integer_div(dest, l, r, error_code)
      end
    end

    # R[a] = global[symbols[b]]
    #
    # **普通の読み取りを先に置きます。** 種別を 1 回見るだけで済むので、
    # 桁付きやデバイス族のための比較を通りません。命令の本体に置いた比較は
    # その命令が走るたびに効くため、いちばん多く通る枝を先頭にします。
    def load_global_into_reg(dest, sym_operand, heap_code)
      device_table_lookup(sym_operand)
      note "レジスタアドレス"
      slot = global_reg_slot(dest)
      note "種別で 4 つに分ける。いちばん多い普通のデバイスがここで決まる"
      chain_head(true, "Z1 = #{SYMBOL_KIND_VALUE}")
      indent
      device_dispatch(:read, slot: slot, error_code: 0x15)
      dedent
      chain_head(false, "Z1 = #{SYMBOL_KIND_GLOBAL}")
      indent
      note "汎用グローバルは値スロット。型タグごと写す"
      line "Z3 = Z6"
      copy_slot(from: 3, to: slot.z)
      dedent
      chain_head(false, "Z1 = #{SYMBOL_KIND_FAMILY}")
      indent
      assign_device_ref(slot)
      dedent
      line "ELSE"
      indent
      load_string_from_device(slot, 0x15, heap_code)
      dedent
      line "END IF"
    end

    # デバイスから文字列を読む
    #
    # **桁数がそのままバイト数**です。桁が空白や 0 で埋まっていれば、それも
    # 中身に入ります。**何も落としません。** 落とす規則を持つと、末尾の空白が
    # 意味を持つデータを扱えなくなるためです。
    #
    # 桁の無い `T` (桁数 0) は読めません。書くときは終端付きの意味ですが、
    # 読むときは長さが決まらないためです。
    #
    # 並びが同じ (1 ワード 2 バイト、先の文字が上位) なので、ワード単位で
    # そのまま写せます。**プールを 1 スロット使います。**
    def load_string_from_device(slot, error_code, heap_code)
      note "文字列を読めるのは #{WORD_DEVICES.map(&:last).join(' / ')} だけ"
      note "**この検査は FOR の外に置く。** 中の BREAK は FOR を抜けるだけで"
      note "命令ループから出られず、エラーを書いてもそのまま走り続ける"
      if_("Z5 > #{DEVICE_TYPE_ZF}") { vm_error(error_code) }
      line "#{str_temp} = Z8 / #{ACCESS_STR_LENGTH_SCALE}   ' 桁数 = バイト数"
      if_("#{str_temp} = 0") do
        note "桁の無い T は読めない。長さが決まらない"
        vm_error(error_code)
      end
      if_("#{str_temp} > #{layout.max_string_bytes}") do
        note "1 スロットに収まらない桁数"
        vm_error(heap_code)
      end
      note "プールの空きスロットを取る。返さないので使い切ったら止まる"
      if_("#{state(layout.array_sp_addr)} >= #{layout.max_arrays}") { vm_error(heap_code) }

      line "Z3 = #{state(layout.array_sp_addr)} * #{layout.array_slot_words} + " \
           "#{block_offset(layout.array_pool_base)}"
      line "#{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z3 = #{str_temp}"
      note "ワード単位で写す。並びが同じなので詰め替えは要らない"
      line "#{str_limit} = #{str_temp} + 1"
      line "#{str_limit} = #{str_limit} / 2   ' ワード数"
      if_("#{str_limit} > 0") do
        line "#{str_limit} = #{str_limit} - 1"
        line "FOR #{str_index} = 0 TO #{str_limit}"
        indent
        line "Z4 = #{str_index} + Z6   ' デバイスの位置"
        note "ワードデバイスから 1 ワード。種別は FOR に入る前に検査済み"
        first = true
        last = WORD_DEVICES.last
        WORD_DEVICES.each do |type, name|
          if [type, name] == last
            line "ELSE"
          else
            chain_head(first, "Z5 = #{type}")
            first = false
          end
          indent
          line "Z7 = #{name}0.U:Z4"
          dedent
        end
        line "END IF"
        line "Z4 = #{str_index} + Z3 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
        line "#{layout.device_name}0:Z4 = Z7"
        dedent
        line "NEXT"
      end
      note "桁が奇数なら最後のワードの下位バイトは桁の外。0 にして中身に混ぜない"
      note "残すと同じ中身どうしの == がワード単位の比較で外れる"
      line "#{str_limit} = #{str_temp} / 2"
      line "#{str_flag} = #{str_limit} * 2"
      if_("#{str_temp} <> #{str_flag}") do
        line "Z4 = #{str_limit} + Z3 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
        line "Z7 = #{layout.device_name}0:Z4"
        line "Z7 = Z7 / 256"
        line "#{layout.device_name}0:Z4 = Z7 * 256"
      end
      line "#{slot.value} = #{state(layout.array_sp_addr)}   ' スロット番号"
      line "#{slot.tag} = #{TT_STRING}"
      line "#{state(layout.array_sp_addr)} = #{state(layout.array_sp_addr)} + 1"
    end

    def store_reg_into_global(sym_operand, src)
      device_table_lookup(sym_operand)
      note "レジスタアドレス"
      slot = global_reg_slot(src)
      chain_head(true, "Z1 = #{SYMBOL_KIND_GLOBAL}")
      indent
      note "汎用グローバルは値スロット。型タグごと写す"
      line "Z3 = Z6"
      copy_slot(from: slot.z, to: 3)
      dedent
      chain_head(false, "Z1 = #{SYMBOL_KIND_FAMILY}")
      indent
      note "デバイス族そのものへの代入 ($DM = 1) は意味を持たない"
      vm_error(0x16)
      dedent
      chain_head(false, "#{slot.tag} = #{TT_STRING}")
      indent
      store_string_into_device(slot, 0x16)
      dedent
      line "ELSE"
      indent
      if_("Z8 >= #{ACCESS_STR}") do
        note "文字列の桁 (T) に文字列以外を書こうとした"
        vm_error(0x16)
      end
      prepare_write_scratches(slot)
      device_dispatch(:write, slot: slot, error_code: 0x16)
      dedent
      line "END IF"
    end

    # 文字列をデバイスへ書く
    #
    # 2 つの形があります。桁数はシンボル表の幅ワードに
    # `#{'ACCESS_STR'} + 桁数 * #{'ACCESS_STR_LENGTH_SCALE'}` で詰めてあります。
    #
    #   桁数 0  終端付き。バイト列の後ろに 0 を 1 つ足す
    #   桁数 n  固定長。足りなければ FARUBY_STR_FILL で埋め、
    #           はみ出す分は切り詰める。ちょうどなら終端は書かない
    #
    # 並びが同じ (1 ワード 2 バイト、先の文字が上位) なので、中身が 2 バイトとも
    # 揃っているワードはそのまま写します。半端になるのは末尾の 1 ワードだけです。
    def store_string_into_device(slot, error_code)
      note "文字列を書けるのは #{WORD_DEVICES.map(&:last).join(' / ')} だけ"
      note "**この検査は FOR の外に置く。** 中の BREAK は FOR を抜けるだけで"
      note "命令ループから出られず、エラーを書いてもそのまま走り続ける"
      if_("Z5 > #{DEVICE_TYPE_ZF}") { vm_error(error_code) }
      note "桁数。0 なら終端付き"
      line "Z7 = Z8 / #{ACCESS_STR_LENGTH_SCALE}"
      note "文字列スロットの見出し"
      line "Z4 = #{slot.value}"
      line "Z4 = Z4 * #{layout.array_slot_words} + #{block_offset(layout.array_pool_base)}"
      line "#{scratch32_b} = #{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z4   ' バイト数"

      note "書く長さと埋めるバイトを決める"
      if_else_block("Z7 = 0") do
        note "終端付き。バイト列 + 0"
        line "#{scratch32} = #{scratch32_b} + 1"
        line "Z8 = 0"
      end
      note "固定長。余りは FARUBY_STR_FILL"
      line "#{scratch32} = Z7"
      line "Z8 = #{state(layout.str_fill_addr)}"
      end_block

      note "中身の長さ。桁からはみ出す分は切り詰める"
      if_("#{scratch32_b} > #{scratch32}") { line "#{scratch32_b} = #{scratch32}" }

      note "ワード数。奇数バイトなら最後のワードの下位バイトは埋めるバイト"
      line "Z2 = #{scratch32} + 1"
      line "Z2 = Z2 / 2"
      if_("Z2 > 0") do
        line "Z2 = Z2 - 1"
        line "FOR Z3 = 0 TO Z2"
        indent
        line "Z1 = Z3 * 2   ' 先頭バイトの位置"
        line "Z7 = Z1 + 1"
        if_else_block("Z7 < #{scratch32_b}") do
          note "2 バイトとも中身。並びが同じなのでそのまま写す"
          line "Z7 = Z3 + Z4 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
          line "Z7 = #{layout.device_name}0:Z7"
        end
        note "末尾の半端なワード。バイトごとに決める"
        line "Z7 = 0"
        if_else_block("Z1 < #{scratch32_b}") do
          line "Z7 = Z3 + Z4 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
          line "Z7 = #{layout.device_name}0:Z7"
          line "Z7 = Z7 / 256   ' 上位バイトだけ中身"
        end
        if_("Z1 < #{scratch32}") { line "Z7 = Z8" }
        end_block
        line "Z7 = Z7 * 256"
        line "Z1 = Z1 + 1"
        if_("Z1 < #{scratch32}") { line "Z7 = Z7 + Z8" }
        end_block

        note "ワードデバイスへ 1 ワード。種別は FOR に入る前に検査済み"
        line "Z1 = Z3 + Z6"
        first = true
        last = WORD_DEVICES.last
        WORD_DEVICES.each do |type, name|
          if [type, name] == last
            line "ELSE"
          else
            chain_head(first, "Z5 = #{type}")
            first = false
          end
          indent
          line "#{name}0.U:Z1 = Z7"
          dedent
        end
        line "END IF"
        dedent
        line "NEXT"
      end
    end

    # --- 添字によるデバイスアクセス ---
    #
    # $DM[100 + i] のように実行時にアドレスを決める経路です。
    # OP_GETIDX / OP_SETIDX は専用命令なので、メソッド呼び出しは要りません。

    # R[a] = R[a][R[a+1]]
    def load_device_index(name, error_code, heap_code)
      ref = reg_slot(name)          # デバイス参照または配列 (結果の格納先でもある)
      index = reg_next_slot(name)   # 添字

      line "IF #{ref.tag} = #{TT_DEVICE} THEN"
      indent
      device_ref_lookup(ref, index.value, error_code)
      if_else_block("Z8 >= #{ACCESS_STR}") { load_string_from_device(ref, error_code, heap_code) }
      device_dispatch(:read, slot: ref, error_code: error_code)
      end_block
      dedent
      line "ELSE IF #{ref.tag} = #{TT_ARRAY} THEN"
      indent
      load_array_index(ref, index)
      dedent
      line "ELSE IF #{ref.tag} = #{TT_HASH} THEN"
      indent
      load_hash_index(ref, index)
      dedent
      line "ELSE IF #{ref.tag} = #{TT_STRING} THEN"
      indent
      load_string_index(ref, index, heap_code)
      dedent
      line "ELSE"
      indent
      note "デバイス参照・配列・ハッシュ・文字列以外への添字アクセスは未対応"
      vm_error(error_code)
      end_block
    end

    # R[a][R[a+1]] = R[a+2]
    def store_device_index(name, error_code, heap_code)
      ref = reg_slot(name)
      index = reg_next_slot(name)
      value = slot_ref([:reg_value, name], "(#{operand(name)} + 2) * #{SLOT_WORDS}",
                       reg_offset, z: Z_VALUE)

      line "IF #{ref.tag} = #{TT_DEVICE} THEN"
      indent
      device_ref_lookup(ref, index.value, error_code)
      chain_head(true, "#{value.tag} = #{TT_STRING}")
      indent
      store_string_into_device(value, error_code)
      dedent
      chain_head(false, "Z8 >= #{ACCESS_STR}")
      indent
      note "文字列の桁 (T) に文字列以外を書こうとした"
      vm_error(error_code)
      dedent
      line "ELSE"
      indent
      prepare_write_scratches(value)
      device_dispatch(:write, slot: value, error_code: error_code)
      dedent
      line "END IF"
      dedent
      line "ELSE IF #{ref.tag} = #{TT_ARRAY} THEN"
      indent
      store_array_index(ref, index, value, error_code, heap_code)
      dedent
      line "ELSE IF #{ref.tag} = #{TT_HASH} THEN"
      indent
      store_hash_index(ref, index, value, heap_code)
      dedent
      line "ELSE"
      indent
      note "デバイス参照・配列・ハッシュ以外への添字代入は未対応"
      vm_error(error_code)
      end_block
    end

    # --- 配列の添字アクセス ---
    #
    # Z1 は R[a] (配列そのもの)、Z2 は R[a+1] (添字)、Z3 は OP_SETIDX の
    # R[a+2] (書き込む値) が使っています。**Z4 以降しか使えません。**

    Z_ARRAY_SLOT    = 4   # スロットの見出し
    Z_ARRAY_ELEMENT = 5   # 要素の先頭

    # スロットの見出しを Z4 に、要素数を32ビットスクラッチ B に置く
    #
    # ref は R[a] で結果の格納先でもあるため、**書き換える前に**呼びます。
    def array_slot_into_z(ref)
      note "スロットの見出し。R[a] を書き換える前に読む"
      line "Z#{Z_ARRAY_SLOT} = #{ref.value}"
      line "Z#{Z_ARRAY_SLOT} = Z#{Z_ARRAY_SLOT} * #{layout.array_slot_words} + " \
           "#{block_offset(layout.array_pool_base)}"
      line "#{scratch32_b} = #{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z#{Z_ARRAY_SLOT}" \
           "   ' 要素数"
    end

    # 負の添字を後ろからの位置に直して32ビットスクラッチに置く
    #
    # Ruby の a[-1] は最後の要素です。直しても負のままなら範囲外。
    def normalize_array_index(index)
      note "負の添字は後ろから数える (Ruby の a[-1] は最後の要素)"
      line "#{scratch32} = #{index.value}"
      if_("#{scratch32} < 0") { line "#{scratch32} = #{scratch32} + #{scratch32_b}" }
    end

    # 添字の位置にある要素の先頭を Z5 に置く
    def array_element_into_z
      line "Z#{Z_ARRAY_ELEMENT} = #{scratch32}"
      line "Z#{Z_ARRAY_ELEMENT} = Z#{Z_ARRAY_ELEMENT} * #{SLOT_WORDS} + Z#{Z_ARRAY_SLOT} + " \
           "#{MemoryLayout::ARRAY_HEADER_WORDS}"
      slot_on(Z_ARRAY_ELEMENT)
    end

    # R[a] = nil (添字が範囲外のとき)
    def set_slot_nil(slot)
      line "#{slot.value} = #{TT_CANONICAL_VALUE.fetch(TT_NIL)}"
      line "#{slot.tag} = #{TT_NIL}"
    end

    # R[a] = R[a][R[a+1]] (文字列)
    #
    # Ruby と同じく**1 文字の文字列**を返します。範囲外は nil です。
    # 負の添字は後ろから数えるので、先に文字数を数えます。
    #
    # **プールを 1 スロット使います。** ループの中で呼び続けると使い切ります。
    def load_string_index(ref, index, heap_code)
      string_header_into(4, ref.value)
      line "#{scratch32} = #{index.value}"
      if_("#{scratch32} < 0") do
        note "負の添字は後ろから数える。文字数が要るので一度なめる"
        line "#{str_target} = #{STR_NO_TARGET}"
        scan_string_characters
        line "#{scratch32} = #{scratch32} + #{str_count}"
      end
      line "IF #{scratch32} < 0 THEN"
      indent
      note "後ろから数えても先頭より前。範囲外は nil (Ruby と同じ)"
      set_slot_nil(ref)
      dedent
      line "ELSE IF #{scratch32} > #{layout.max_string_bytes} THEN"
      indent
      note "1 文字 1 バイト以上なので、バイト数を超える番号は必ず範囲外"
      set_slot_nil(ref)
      dedent
      line "ELSE"
      indent
      line "#{str_target} = #{scratch32}"
      scan_string_characters
      if_else_block("#{str_found} >= #{str_limit}") do
        note "そこまで文字が無い。範囲外は nil (Ruby と同じ)"
        set_slot_nil(ref)
      end
      note "プールの空きスロットを取る。返さないので使い切ったら止まる"
      if_("#{state(layout.array_sp_addr)} >= #{layout.max_arrays}") { vm_error(heap_code) }
      string_header_into(3, state(layout.array_sp_addr))
      line "#{scratch32} = 0   ' 新しいスロットは空から始める"
      line "#{scratch32_b} = #{str_found_end} - #{str_found}   ' その文字のバイト数"
      append_string_bytes(source_offset: str_found)
      line "#{ref.value} = #{state(layout.array_sp_addr)}   ' スロット番号"
      line "#{ref.tag} = #{TT_STRING}"
      line "#{state(layout.array_sp_addr)} = #{state(layout.array_sp_addr)} + 1"
      end_block
      dedent
      line "END IF"
    end

    # R[a] = R[a][R[a+1]] (配列)
    #
    # 範囲外は Ruby と同じく nil。エラーにはしません。
    def load_array_index(ref, index)
      array_slot_into_z(ref)
      normalize_array_index(index)
      note "範囲外は nil (Ruby と同じ)。エラーにはしない"
      line "IF #{scratch32} < 0 THEN"
      indent
      set_slot_nil(ref)
      dedent
      line "ELSE IF #{scratch32} >= #{scratch32_b} THEN"
      indent
      set_slot_nil(ref)
      dedent
      line "ELSE"
      indent
      element = array_element_into_z
      line "#{ref.value} = #{element.value}"
      line "#{ref.tag} = #{element.tag}"
      end_block
    end

    # R[a][R[a+1]] = R[a+2] (配列)
    #
    # Ruby は要素数を超える添字への代入で配列を伸ばし、間を nil で埋めます。
    # 容量は固定なので、**容量を超えたらエラー**です。
    def store_array_index(ref, index, value, error_code, heap_code)
      array_slot_into_z(ref)
      normalize_array_index(index)
      if_("#{scratch32} < 0") do
        note "後ろから数えても先頭より前 (Ruby は IndexError)"
        vm_error(error_code)
      end
      if_("#{scratch32} >= #{layout.max_array_len}") do
        note "1 スロットの容量を超える位置"
        vm_error(heap_code)
      end
      note "要素数を超える位置への代入は、間を nil で埋めて伸ばす"
      if_("#{scratch32} > #{scratch32_b}") do
        line "Z6 = #{scratch32_b}   ' 埋め始め (今の要素数)"
        line "Z7 = #{scratch32}"
        line "Z7 = Z7 - 1   ' 埋め終わり。ここは添字 > 要素数 >= 0 なので 0 未満にならない"
        line "FOR Z8 = Z6 TO Z7"
        indent
        line "Z#{Z_ARRAY_ELEMENT} = Z8 * #{SLOT_WORDS} + Z#{Z_ARRAY_SLOT} + " \
             "#{MemoryLayout::ARRAY_HEADER_WORDS}"
        set_slot_nil(slot_on(Z_ARRAY_ELEMENT))
        dedent
        line "NEXT"
      end
      if_("#{scratch32} >= #{scratch32_b}") do
        line "Z6 = #{scratch32}"
        line "#{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z#{Z_ARRAY_SLOT} = Z6 + 1" \
             "   ' 要素数を伸ばす"
      end
      element = array_element_into_z
      line "#{element.value} = #{value.value}"
      line "#{element.tag} = #{value.tag}"
    end

    # --- 実行中の irep ---

    # 実行をトップレベルの irep に戻す (リセット時)
    #
    # IREP テーブルの 0 番から VM 状態へ写します。テーブルの内容はプログラムを
    # 転送するたびに変わるため、生成コードに焼き込むことはできません。
    def reset_to_top_irep
      note "実行中の irep をトップレベル (0番) に戻す"
      line "#{state(layout.frame_sp_addr)} = 0      ' 呼び出しの深さ"
      line "#{state(layout.array_sp_addr)} = 0      ' 配列プールの空き先頭"
      line "#{state(layout.reg_base_addr)} = #{layout.offset_of(layout.reg_file_base)}" \
           "      ' レジスタ窓の先頭"
      line "#{state(layout.cur_irep_addr)} = 0"
      load_irep_state(irep_table_offset)
    end

    # IREP テーブルの 1 エントリを VM 状態へ写す
    #
    # 命令ごとにテーブルを引くとスキャンタイムが延びるため、切り替え時に
    # 写して使います。table_expr はエントリ先頭を指す Z の設定式。
    def load_irep_state(table_expr)
      note "IREP テーブルから実行中の irep の情報を写す"
      line "Z#{Z_PRIMARY} = #{table_expr}"
      { MemoryLayout::IREP_BYTECODE     => layout.cur_bytecode_addr,
        MemoryLayout::IREP_BYTECODE_LEN => layout.bytecode_len_addr,
        MemoryLayout::IREP_POOL         => layout.cur_pool_addr,
        MemoryLayout::IREP_SYMBOLS      => layout.cur_symbols_addr,
        MemoryLayout::IREP_NREGS        => layout.nregs_addr }.each do |field, addr|
        line "#{state(addr)} = #{layout.fixed_device_name}#{field}:Z#{Z_PRIMARY}"
      end
    end

    # --- メソッドの定義と呼び出し ---

    # R[a] = 子 irep b への参照 (OP_METHOD)
    #
    # irep は階層ごとに並べてあり同じ親の子が連続するため、実行中の irep の
    # 「最初の子の番号」に b を足せば通し番号になります。
    def load_child_irep(name, child_name, error_code)
      child_irep_into(scratch_lo, child_name, error_code)
      dest = reg_slot(name)
      line "#{dest.word(0)} = #{scratch_lo}   ' 本体の irep"
      line "#{dest.word(1)} = #{MemoryLayout::FRAME_NONE}   ' メソッドは外側を見ない"
      line "#{dest.tag} = #{TT_PROC}"
    end

    # 親から見た子の番号を通し番号に直す
    def child_irep_into(dest, child_name, error_code)
      note "実行中の irep の最初の子の番号に、親から見た子の番号を足す"
      line "Z3 = #{state(layout.cur_irep_addr)} * #{MemoryLayout::IREP_TABLE_STRIDE} + " \
           "#{irep_table_offset}"
      line "Z4 = Z3 + #{MemoryLayout::IREP_FIRST_CHILD}"
      line "#{dest} = #{fixed_indexed_base}:Z4 + #{operand(child_name)}"
      if_("#{dest} >= #{state(layout.num_ireps_addr)}") do
        note "指す先の irep が無い"
        vm_error(error_code)
      end
    end

    # メソッド表に symbols[b] = R[a+1] を登録する (OP_DEF)
    #
    # 名前はホスト側でユーザー定義メソッド ID に解決済みです。シンボル表は
    # irep ごとに別なので、ID を挟まないとどのエントリから呼んでも同じ
    # メソッドに行き着きません。
    def define_method(name, sym_name, error_code)
      method_table_lookup(sym_name)
      if_("Z4 <> #{SYMBOL_KIND_METHOD}") { vm_error(error_code) }
      line "Z3 = Z3 + 1"
      line "Z5 = #{fixed_indexed_base}:Z3   ' ユーザー定義メソッドID"
      if_("Z5 = #{METHOD_ID_NONE}") do
        note "組み込みと同じ名前は再定義できない"
        vm_error(error_code)
      end
      body = reg_next_slot(name)
      if_("#{body.tag} <> #{TT_PROC}") { vm_error(error_code) }
      note "メソッド表 (ID => 本体の irep 番号)"
      line "Z3 = Z5 + #{layout.offset_of(layout.method_table_base)} + Z#{Z_INSTANCE}"
      line "#{indexed_base}:Z3 = #{body.word(0)}"
      note "OP_DEF の戻り値はメソッド名の Symbol。トップレベルでは捨てられる"
      dest = reg_slot(name)
      line "#{dest.value} = #{operand(sym_name)}"
      line "#{dest.tag} = #{TT_SYMBOL}"
    end

    # R[a] = self.メソッド(R[a+1]..) (OP_SSEND)
    #
    # mruby は R[a] に self を置いてから OP_SEND と同じ経路に入ります。
    # 組み込みならその場で計算し、ユーザー定義ならフレームを積んで移ります。
    def send_self_method(name, sym_name, argc_name, unknown_code, type_code,
                         zero_code, heap_code, depth_code)
      note "self をレシーバ位置に置く (mruby の regs[a] = regs[0])"
      self_slot = slot_ref([:reg_self, name], "0", reg_offset, z: Z_VALUE)
      dest = reg_slot(name)
      line "#{dest.value} = #{self_slot.value}"
      line "#{dest.tag} = #{self_slot.tag}"

      method_table_lookup(sym_name)
      if_("Z4 <> #{SYMBOL_KIND_METHOD}") { vm_error(unknown_code) }
      line "Z3 = Z3 + 1"
      line "Z6 = #{fixed_indexed_base}:Z3   ' ユーザー定義メソッドID"

      if_else_block("Z5 <> #{METHOD_NONE}") do
        note "組み込みメソッド。フレームを積まずその場で計算する"
        builtin_dispatch(name, argc_name, unknown_code, type_code, zero_code, heap_code)
      end
      call_user_method(name, argc_name, unknown_code, depth_code)
      end_block
    end

    # ユーザー定義メソッドへ移る
    def call_user_method(name, argc_name, unknown_code, depth_code)
      if_("Z6 = #{METHOD_ID_NONE}") do
        note "組み込みでもユーザー定義でもない"
        vm_error(unknown_code)
      end
      line "Z3 = Z6 + #{layout.offset_of(layout.method_table_base)} + Z#{Z_INSTANCE}"
      line "Z5 = #{indexed_base}:Z3   ' 本体の irep 番号"
      if_("Z5 = #{METHOD_UNDEFINED}") do
        note "まだ def が実行されていない"
        vm_error(unknown_code)
      end

      push_frame(depth_code, "#{operand(name)} * #{SLOT_WORDS}",
                 outer: MemoryLayout::FRAME_NONE)
      line "#{state(layout.call_argc_addr)} = #{operand(argc_name)}"
      switch_to_irep("Z5", depth_code)
      line "#{pc} = 0"
    end

    # 戻り先を呼び出しスタックに積み、レジスタ窓をずらす
    #
    # shift はレジスタ窓を進める量 (呼び出しなら R[a] まで)。呼ばれた側の R[0] が
    # 呼んだ側の R[a] になるため、戻り値の受け渡しが要りません。
    # outer は上位の変数を辿る鎖。メソッドは上位を見ないので FRAME_NONE です。
    def push_frame(depth_code, shift, outer:, kind: MemoryLayout::FRAME_KIND_CALL)
      if_("#{state(layout.frame_sp_addr)} >= #{layout.max_frames}") do
        note "呼び出しが深すぎる。PLC はメモリ固定なので上限で止めるしかない"
        vm_error(depth_code)
      end
      note "戻り先を積む"
      line "Z3 = #{frame_expr(state(layout.frame_sp_addr))}"
      { MemoryLayout::FRAME_RETURN_PC   => pc,
        MemoryLayout::FRAME_RETURN_IREP => state(layout.cur_irep_addr),
        MemoryLayout::FRAME_RETURN_BASE => state(layout.reg_base_addr),
        MemoryLayout::FRAME_OUTER       => outer,
        MemoryLayout::FRAME_KIND        => kind }.each do |field, value|
        line "#{layout.device_name}#{field}:Z3 = #{value}"
      end
      note "レジスタ窓をずらす。呼ばれた側の R[0] が呼んだ側の R[a]"
      line "#{state(layout.reg_base_addr)} = #{state(layout.reg_base_addr)} + #{shift}"
      line "#{layout.device_name}#{MemoryLayout::FRAME_OWN_BASE}:Z3 = " \
           "#{state(layout.reg_base_addr)}   ' このフレームの窓 (OP_GETUPVAR が見る)"
      line "#{state(layout.frame_sp_addr)} = #{state(layout.frame_sp_addr)} + 1"
    end

    # R[a] = :name (OP_LOADSYM)
    #
    # 値はシンボル表の 2 ワード目 (ホストが名前ごとに振った通し番号) です。
    # 索引をそのまま使うと irep をまたいで同じ名前が別物になります。
    def load_symbol(name, sym_name, error_code)
      method_table_lookup(sym_name)
      if_("Z4 <> #{SYMBOL_KIND_METHOD}") do
        note "デバイス名や変数名はシンボルとして扱えない"
        vm_error(error_code)
      end
      line "Z3 = Z3 + 1"
      line "Z6 = #{fixed_indexed_base}:Z3   ' シンボルの通し番号"
      dest = reg_slot(name)
      line "#{dest.value} = Z6"
      line "#{dest.tag} = #{TT_SYMBOL}"
    end

    # --- 配列 ---

    # R[dest] = [R[first] .. R[first+count-1]] (OP_ARRAY / OP_ARRAY2)
    #
    # 実体は配列プールのスロットに置き、レジスタにはスロット番号だけを
    # 入れます。スロットは順に渡して返しません。使い切ったら止まります。
    #
    # OP_ARRAY は dest と first が同じレジスタなので、**要素を写し終えて
    # から R[dest] を書きます。**
    def new_array(dest_name, first_name, count_name, error_code)
      note "プールの空きスロットを取る。返さないので使い切ったら止まる"
      if_("#{state(layout.array_sp_addr)} >= #{layout.max_arrays}") { vm_error(error_code) }
      if_("#{operand(count_name)} > #{layout.max_array_len}") do
        note "1 スロットの容量を超える要素数"
        vm_error(error_code)
      end
      note "スロットの見出し"
      line "Z2 = #{state(layout.array_sp_addr)} * #{layout.array_slot_words} + " \
           "#{block_offset(layout.array_pool_base)}"
      line "#{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z2 = #{operand(count_name)}"
      note "要素を写す。要素数 0 (空配列) では引き算もしない"
      note "EM は16ビット符号なしのため、0 - 1 は 65535 になり得る"
      if_("#{operand(count_name)} > 0") do
        line "Z3 = #{operand(count_name)} - 1"
        line "FOR Z4 = 0 TO Z3"
        indent
        line "Z5 = (#{operand(first_name)} + Z4) * #{SLOT_WORDS} + #{reg_offset}"
        line "Z6 = Z4 * #{SLOT_WORDS} + Z2 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
        src = slot_on(5)
        element = slot_on(6)
        line "#{element.value} = #{src.value}"
        line "#{element.tag} = #{src.tag}"
        dedent
        line "NEXT"
      end
      dest = reg_slot(dest_name)
      line "#{dest.value} = #{state(layout.array_sp_addr)}   ' スロット番号"
      line "#{dest.tag} = #{TT_ARRAY}"
      line "#{state(layout.array_sp_addr)} = #{state(layout.array_sp_addr)} + 1"
    end

    # 既に Z に載っている先頭アドレスを値スロットとして扱う
    #
    # slot_ref と違い Z を計算する行は出しません。呼ぶ側が FOR の中などで
    # 自分で載せた場合に使います。
    def slot_on(z)
      Slot.new("#{layout.device_name}#{SLOT_TYPE_OFFSET}:Z#{z}", z, layout.device_name)
    end

    # --- 文字列 ---
    #
    # 実体は配列プールのスロットです。見出しの後ろに **1 ワード 2 バイト、
    # 先の文字が上位バイト**で詰めます。KV の文字列デバイスと同じ並びなので、
    # デバイスとの行き来がワード単位の写しで済みます。
    #
    # バイト列は変換しません。ソースの文字コードがそのままデバイスへ出ます。

    # R[a] = pool[b] の複製 (OP_STRING)
    #
    # **毎回複製します。** Ruby の文字列は変更できるので、同じリテラルを 2 回
    # 書けば別のものです。リテラルを書くたびにスロットを 1 つ使います。
    def new_string(name, pool_name, error_code)
      src = pool_slot(pool_name)
      note "文字列は値スロットに入らない。位置とバイト数だけが入っている"
      line "Z3 = #{src.word(0)}   ' 文字列領域の位置 (ワード)"
      line "Z4 = #{src.word(1)}   ' バイト数"
      note "プールの空きスロットを取る。返さないので使い切ったら止まる"
      if_("#{state(layout.array_sp_addr)} >= #{layout.max_arrays}") { vm_error(error_code) }
      if_("Z4 > #{layout.max_string_bytes}") do
        note "1 スロットに収まらない (ホストでも見ているが念のため)"
        vm_error(error_code)
      end
      note "スロットの見出しはバイト数"
      line "Z5 = #{state(layout.array_sp_addr)} * #{layout.array_slot_words} + " \
           "#{block_offset(layout.array_pool_base)}"
      line "#{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z5 = Z4"
      note "ワード単位で写す。並びが同じなので詰め替えは要らない"
      note "奇数バイトのときは最後のワードの下位バイトが 0 になる"
      line "Z6 = (Z4 + 1) / 2   ' ワード数"
      if_("Z6 > 0") do
        line "Z6 = Z6 - 1"
        line "FOR Z7 = 0 TO Z6"
        indent
        line "Z8 = Z7 + Z3 + #{fixed_offset(layout.string_pool_base)}"
        line "Z2 = Z7 + Z5 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
        line "#{layout.device_name}0:Z2 = #{layout.fixed_device_name}0:Z8"
        dedent
        line "NEXT"
      end
      dest = reg_slot(name)
      line "#{dest.value} = #{state(layout.array_sp_addr)}   ' スロット番号"
      line "#{dest.tag} = #{TT_STRING}"
      line "#{state(layout.array_sp_addr)} = #{state(layout.array_sp_addr)} + 1"
    end

    # --- 文字列の中身を比べる ---
    #
    # スロット番号だけを比べると、同じ内容が別のスロットにあるときに
    # 等しくなりません。**Ruby の文字列は中身で比べます。**
    #
    # 並びが揃っている (1 ワード 2 バイト、奇数バイトの余りは 0) ので、
    # バイト数が同じならワード単位で比べられます。回数はバイト数の半分です。

    def str_index = state(layout.str_index_addr)
    def str_flag  = state(layout.str_flag_addr)
    def str_temp  = state(layout.str_temp_addr)
    def str_limit = state(layout.str_limit_addr)
    def str_saved_z = state(layout.str_saved_z_addr)
    def str_count     = state(layout.str_count_addr)
    def str_skip      = state(layout.str_skip_addr)
    def str_target    = state(layout.str_target_addr)
    def str_found     = state(layout.str_found_addr)
    def str_found_end = state(layout.str_found_end_addr)

    # 探している文字が無いことを表す番号 (16ビットに収まる最大値)
    #
    # 文字数を数えるだけのときに置きます。文字列は max_string_bytes バイトまで
    # なので、この番号が本物の文字番号とぶつかることはありません。
    STR_NO_TARGET = 65535

    # 位置 position のバイトを Z7 に取り出す (Z4 が文字列スロットの見出し)
    #
    # 1 ワード 2 バイトで**先の文字が上位**なので、偶数の位置は上位バイト、
    # 奇数の位置は下位バイトです。Z8 を作業に使います。
    def string_byte_into_z7(position)
      line "Z8 = #{position} / 2"
      line "Z7 = Z8 + Z4 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
      line "Z7 = #{layout.device_name}0:Z7"
      line "Z8 = Z8 * 2"
      if_else_block("#{position} = Z8") { line "Z7 = Z7 / 256   ' 偶数の位置は上位バイト" }
      line "Z8 = Z7 / 256"
      line "Z7 = Z7 - Z8 * 256   ' 奇数の位置は下位バイト"
      end_block
    end

    # 文字の切れ目を先頭から数える
    #
    # 入力  Z4         文字列スロットの見出し
    #       str_target 探している文字の番号 (STR_NO_TARGET なら数えるだけ)
    # 出力  str_limit     バイト数
    #       str_count     文字数
    #       str_found     探している文字の先頭バイト (無ければ str_limit)
    #       str_found_end その次の文字の先頭バイト
    #
    # `"あ".length` は Ruby では 1 です。**バイト数ではなく文字数**を返すため、
    # バイト列を 1 回なめて切れ目を数えます。同じ走査で `s[i]` の位置も出ます。
    #
    # **Shift_JIS は自己同期しません。** 後続バイトの範囲が ASCII と重なるので、
    # バイト 1 つを見ても先導か後続か分かりません。必ず先頭から走査します。
    #
    # 作業に Z6・Z7・Z8 を使います。**Z6 は FOR の上限**なので中で触れません。
    def scan_string_characters
      note "文字の切れ目を先頭から数える。バイト列は 1 回だけなめる"
      line "#{str_limit} = #{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z4   ' バイト数"
      line "#{str_count} = 0"
      line "#{str_skip} = 0"
      line "#{str_found} = #{str_limit}   ' 見つからなければバイト数のまま"
      line "#{str_found_end} = #{str_limit}"
      if_("#{str_limit} > 0") do
        line "Z6 = #{str_limit}"
        line "Z6 = Z6 - 1"
        line "FOR #{str_index} = 0 TO Z6"
        indent
        string_byte_into_z7(str_index)
        note "この位置が文字の先頭かどうか"
        line "#{str_flag} = 1"
        line "IF #{state(layout.str_encoding_addr)} = #{ENCODING_UTF8} THEN"
        indent
        note "継続バイト (10xxxxxx) は文字の途中"
        if_("Z7 >= 128") { if_("Z7 < 192") { line "#{str_flag} = 0" } }
        dedent
        line "ELSE IF #{state(layout.str_encoding_addr)} = #{ENCODING_SJIS} THEN"
        indent
        if_else_block("#{str_skip} = 1") do
          note "先導バイトの次は後続バイト"
          line "#{str_flag} = 0"
          line "#{str_skip} = 0"
        end
        note "先導バイト (0x81-0x9F, 0xE0-0xEF) なら次のバイトは後続"
        if_("Z7 >= 129") { if_("Z7 <= 159") { line "#{str_skip} = 1" } }
        if_("Z7 >= 224") { if_("Z7 <= 239") { line "#{str_skip} = 1" } }
        end_block
        dedent
        line "END IF"
        note "ASCII はどのバイトも文字の先頭なので何も見ない"
        if_("#{str_flag} = 1") do
          if_("#{str_target} <= #{layout.max_string_bytes}") do
            note "探している文字なら位置を控える。次の切れ目がその文字の終わり"
            if_("#{str_count} = #{str_target}") { line "#{str_found} = #{str_index}" }
            line "Z7 = #{str_target} + 1"
            if_("#{str_count} = Z7") { line "#{str_found_end} = #{str_index}" }
          end
          line "#{str_count} = #{str_count} + 1"
        end
        dedent
        line "NEXT"
      end
    end

    # スロット番号の式からスロットの見出しを Z3 に置く
    def string_slot_into_z3(slot_number)
      line "Z3 = #{slot_number}"
      line "Z3 = Z3 * #{layout.array_slot_words} + #{block_offset(layout.array_pool_base)}"
    end

    # 2 つの文字列の中身が同じなら str_flag に 1、違えば 0 を置く
    #
    # **Z3 を借りて返します。** アドレスの計算にインデックスレジスタが要りますが、
    # `OP_SETIDX` は Z3 に書き込む値を載せているため、勝手に潰せません。
    # 借りるのは 1 本だけで、残りの作業は VM 状態の空きワードで行います。
    # FOR のループ変数もデバイスにできるので、これで足ります。
    def compare_string_content(x_value, y_value)
      note "文字列は中身で比べる。スロット番号ではない"
      note "Z3 を借りる。返すまでの間に呼ぶ側の値を壊さないため"
      line "#{str_saved_z} = Z3"
      line "#{str_flag} = 0"
      string_slot_into_z3(x_value)
      line "#{str_temp} = #{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z3   ' バイト数"
      string_slot_into_z3(y_value)
      if_("#{str_temp} = #{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z3") do
        note "バイト数が同じ。ここから中身を見る"
        line "#{str_flag} = 1"
        line "#{str_limit} = #{str_temp} + 1"
        line "#{str_limit} = #{str_limit} / 2   ' ワード数"
        if_("#{str_limit} > 0") do
          line "#{str_limit} = #{str_limit} - 1"
          line "FOR #{str_index} = 0 TO #{str_limit}"
          indent
          string_slot_into_z3(x_value)
          line "Z3 = #{str_index} + Z3 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
          line "#{str_temp} = #{layout.device_name}0:Z3"
          string_slot_into_z3(y_value)
          line "Z3 = #{str_index} + Z3 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
          if_("#{str_temp} <> #{layout.device_name}0:Z3") { line "#{str_flag} = 0" }
          dedent
          line "NEXT"
        end
      end
      note "借りた Z3 を返す"
      line "Z3 = #{str_saved_z}"
    end

    # --- 文字列の継ぎ足し ---

    # 文字列スロットの見出しを Z に置く
    def string_header_into(z, slot_number)
      line "Z#{z} = #{slot_number}"
      line "Z#{z} = Z#{z} * #{layout.array_slot_words} + " \
           "#{block_offset(layout.array_pool_base)}"
    end

    # Z3 の文字列の後ろへ Z4 の文字列を継ぎ足す
    #
    # 長さは scratch32 (継ぎ足す先) と scratch32_b (継ぎ足す元) に置いてから
    # 呼びます。**Z1・Z2 は使いません。** 呼ぶ側がレジスタを載せたままのため、
    # 作業には Z5-Z8 と VM 状態の空きワードを使います。
    #
    # 継ぎ足す先の長さが奇数だとワードの途中から始まるので、**バイト単位**で
    # 書きます。偶数の位置に書くときは下位バイトを 0 にしておき、次のバイトか
    # 詰め物がそこに入ります。
    #
    # source_offset を渡すと、継ぎ足す元の**その位置から**写します
    # (`s[i]` が 1 文字だけを取り出すときに使います)。
    def append_string_bytes(source_offset: nil)
      if_("#{scratch32_b} > 0") do
        line "Z6 = #{scratch32_b}"
        line "Z6 = Z6 - 1"
        line "FOR Z5 = 0 TO Z6"
        indent
        note "継ぎ足す元のバイトを 1 つ取り出す"
        from = "Z5"
        if source_offset
          line "#{str_skip} = #{source_offset} + Z5   ' 元の位置"
          from = str_skip
        end
        line "Z7 = #{from} / 2"
        line "Z8 = Z7 + Z4 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
        line "Z8 = #{layout.device_name}0:Z8"
        line "Z7 = Z7 * 2"
        if_else_block("#{from} = Z7") { line "Z8 = Z8 / 256   ' 偶数の位置は上位バイト" }
        line "Z7 = Z8 / 256"
        line "Z8 = Z8 - Z7 * 256   ' 奇数の位置は下位バイト"
        end_block
        note "書き先の位置 (継ぎ足す先の長さ + 何バイト目か)"
        line "#{str_temp} = #{scratch32} + Z5"
        line "Z7 = #{str_temp}"
        line "Z7 = Z7 / 2"
        line "Z7 = Z7 + Z3 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
        line "#{str_limit} = #{str_temp} / 2"
        line "#{str_limit} = #{str_limit} * 2"
        if_else_block("#{str_temp} = #{str_limit}") do
          note "偶数。下位バイトは 0 にしておく (次のバイトか詰め物が入る)"
          line "#{layout.device_name}0:Z7 = Z8 * 256"
        end
        note "奇数。上位バイトを残して下位に入れる"
        line "#{str_limit} = #{layout.device_name}0:Z7"
        line "#{str_limit} = #{str_limit} / 256"
        line "#{layout.device_name}0:Z7 = #{str_limit} * 256 + Z8"
        end_block
        dedent
        line "NEXT"
      end
      note "長さを更新する"
      line "#{scratch32} = #{scratch32} + #{scratch32_b}"
      line "#{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z3 = #{scratch32}"
    end

    # R[a] = R[a] + R[a+1] (OP_STRCAT)。**継ぎ足す先をそのまま伸ばす**
    def concat_string(name, type_code, heap_code)
      dest = reg_slot(name)
      src = reg_next_slot(name)
      if_("#{dest.tag} <> #{TT_STRING}") { vm_error(type_code) }
      append_string_slots(dest, src, type_code, heap_code)
    end

    # dest の後ろへ src を継ぎ足す。dest が文字列であることは呼ぶ側で確かめる
    def append_string_slots(dest, src, type_code, heap_code)
      if_("#{src.tag} <> #{TT_STRING}") { vm_error(type_code) }
      string_header_into(3, dest.value)
      string_header_into(4, src.value)
      line "#{scratch32} = #{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z3"
      line "#{scratch32_b} = #{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z4"
      note "1 スロットに収まること"
      line "Z5 = #{scratch32} + #{scratch32_b}"
      if_("Z5 > #{layout.max_string_bytes}") { vm_error(heap_code) }
      append_string_bytes
    end

    # R[a] = R[a] + R[a+1] を新しいスロットに作る (文字列の +)
    def add_strings(dest, rhs, heap_code)
      note "プールの空きスロットを取る。返さないので使い切ったら止まる"
      if_("#{state(layout.array_sp_addr)} >= #{layout.max_arrays}") { vm_error(heap_code) }
      string_header_into(4, dest.value)
      line "#{scratch32} = #{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z4"
      string_header_into(5, rhs.value)
      line "#{scratch32_b} = #{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z5"
      note "1 スロットに収まること"
      line "Z6 = #{scratch32} + #{scratch32_b}"
      if_("Z6 > #{layout.max_string_bytes}") { vm_error(heap_code) }

      note "新しいスロットへ左側をワード単位で写す。並びが同じなのでそのまま"
      line "Z3 = #{state(layout.array_sp_addr)} * #{layout.array_slot_words} + " \
           "#{block_offset(layout.array_pool_base)}"
      line "#{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z3 = #{scratch32}"
      line "#{str_limit} = #{scratch32} + 1"
      line "#{str_limit} = #{str_limit} / 2"
      if_("#{str_limit} > 0") do
        line "#{str_limit} = #{str_limit} - 1"
        line "FOR #{str_index} = 0 TO #{str_limit}"
        indent
        line "Z7 = #{str_index} + Z4 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
        line "Z8 = #{str_index} + Z3 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
        line "#{layout.device_name}0:Z8 = #{layout.device_name}0:Z7"
        dedent
        line "NEXT"
      end

      note "右側を継ぎ足す。Z4 を継ぎ足す元にする"
      line "Z4 = Z5"
      append_string_bytes

      line "#{dest.value} = #{state(layout.array_sp_addr)}   ' スロット番号"
      line "#{dest.tag} = #{TT_STRING}"
      line "#{state(layout.array_sp_addr)} = #{state(layout.array_sp_addr)} + 1"
    end

    # 定数への代入 (OP_SETCONST)
    #
    # faRuby の設定 (FARUBY_ で始まる名前) だけを VM 状態へ書きます。
    # それ以外の定数は利用者のものなので放っておきます。読む手段
    # (OP_GETCONST) が無いため、使おうとすれば未知のオペコードで止まります。
    def set_constant(name, sym_name)
      line "Z3 = #{operand(sym_name)} * #{DEVICE_TABLE_STRIDE} + #{symbols_offset}"
      line "Z4 = Z3 + #{DEVICE_TABLE_KIND_OFFSET}"
      line "Z5 = #{layout.fixed_device_name}0:Z4   ' シンボル種別"
      if_("Z5 = #{SYMBOL_KIND_SETTING}") do
        line "Z6 = #{layout.fixed_device_name}0:Z3   ' 設定番号"
        src = reg_slot(name)
        if_("Z6 = #{SETTING_STR_FILL}") do
          note "固定長でデバイスへ書いたときの余りを埋めるバイト"
          line "#{state(layout.str_fill_addr)} = #{src.value}"
        end
      end
    end

    # --- ハッシュ ---
    #
    # 実体は配列 2 本です。値スロットの下位に鍵の配列、上位に値の配列の
    # スロット番号を入れます (デバイス参照やブロックと同じ手)。専用のプールを
    # 作らないので、確保も容量検査も配列のものがそのまま使えます。
    #
    # 引き換えにハッシュ 1 つがプールを 2 スロット消費します。

    Z_HASH_KEYS   = 4   # 鍵の配列の見出し
    Z_HASH_VALUES = 5   # 値の配列の見出し

    # R[a] = { R[a] => R[a+1], .. } (OP_HASH)
    #
    # 鍵と値が交互に並んでいるので、1 組ごとに 2 レジスタ進みます。
    def new_hash(name, count_name, error_code)
      note "ハッシュは配列 2 本。空きスロットが 2 つ要る"
      line "Z2 = #{state(layout.array_sp_addr)} + 1"
      if_("Z2 >= #{layout.max_arrays}") { vm_error(error_code) }
      if_("#{operand(count_name)} > #{layout.max_array_len}") do
        note "1 スロットの容量を超える組の数"
        vm_error(error_code)
      end

      note "鍵の配列と値の配列の見出し"
      line "Z2 = #{state(layout.array_sp_addr)} * #{layout.array_slot_words} + " \
           "#{block_offset(layout.array_pool_base)}"
      line "Z3 = Z2 + #{layout.array_slot_words}"
      line "#{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z2 = #{operand(count_name)}"
      line "#{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z3 = #{operand(count_name)}"

      note "組を写す。組の数 0 (空ハッシュ) では引き算もしない"
      if_("#{operand(count_name)} > 0") do
        line "Z4 = #{operand(count_name)} - 1"
        line "FOR Z5 = 0 TO Z4"
        indent
        line "Z6 = (#{operand(name)} + Z5 * 2) * #{SLOT_WORDS} + #{reg_offset}   ' 鍵"
        line "Z7 = Z5 * #{SLOT_WORDS} + Z2 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
        copy_slot(from: 6, to: 7)
        line "Z6 = (#{operand(name)} + Z5 * 2 + 1) * #{SLOT_WORDS} + #{reg_offset}   ' 値"
        line "Z7 = Z5 * #{SLOT_WORDS} + Z3 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
        copy_slot(from: 6, to: 7)
        dedent
        line "NEXT"
      end

      dest = reg_slot(name)
      line "#{dest.word(0)} = #{state(layout.array_sp_addr)}   ' 鍵の配列"
      line "Z2 = #{state(layout.array_sp_addr)} + 1"
      line "#{dest.word(1)} = Z2   ' 値の配列"
      line "#{dest.tag} = #{TT_HASH}"
      line "#{state(layout.array_sp_addr)} = Z2 + 1"
    end

    # Z に載っている値スロットどうしを写す
    def copy_slot(from:, to:)
      src = slot_on(from)
      dst = slot_on(to)
      line "#{dst.value} = #{src.value}"
      line "#{dst.tag} = #{src.tag}"
    end

    # 鍵の配列の見出しを Z4 に、組の数を32ビットスクラッチ B に置く
    #
    # 値の配列が要らないときはこちらを使います。**Z5 を書かない**ので、
    # メソッド番号を持ったままでも呼べます。
    def hash_keys_into_z(ref)
      note "鍵の配列の見出し。R[a] を書き換える前に読む"
      line "Z#{Z_HASH_KEYS} = #{ref.word(0)}"
      line "Z#{Z_HASH_KEYS} = Z#{Z_HASH_KEYS} * #{layout.array_slot_words} + " \
           "#{block_offset(layout.array_pool_base)}"
      line "#{scratch32_b} = #{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z#{Z_HASH_KEYS}" \
           "   ' 組の数"
    end

    # 鍵と値の配列の見出しを Z に置き、組の数を32ビットスクラッチ B に置く
    def hash_slots_into_z(ref)
      hash_keys_into_z(ref)
      line "Z#{Z_HASH_VALUES} = #{ref.word(1)}   ' 値の配列"
      line "Z#{Z_HASH_VALUES} = Z#{Z_HASH_VALUES} * #{layout.array_slot_words} + " \
           "#{block_offset(layout.array_pool_base)}"
    end

    # 鍵を先頭から探し、見つかった位置を32ビットスクラッチに置く (無ければ -1)
    #
    # ハッシュ表は作らず順に見ます。容量が #{'%d'} 程度なら、ハッシュ値を
    # 計算するより速いためです。
    #
    # **一致は型と値の両方**です。Ruby の Hash も `eql?` で引くので
    # `{1 => :a}[1.0]` は `nil` です。ここは合っています。
    def find_hash_key(key)
      note "鍵を先頭から探す。一致は型と値の両方 (Ruby の eql? と同じ)"
      line "#{scratch32} = -1"
      if_("#{scratch32_b} > 0") do
        line "Z8 = #{scratch32_b}"
        line "Z8 = Z8 - 1"
        line "FOR Z6 = 0 TO Z8"
        indent
        if_("#{scratch32} < 0") do
          note "最初に一致したものを採る"
          line "Z7 = Z6 * #{SLOT_WORDS} + Z#{Z_HASH_KEYS} + #{MemoryLayout::ARRAY_HEADER_WORDS}"
          element = slot_on(7)
          if_("#{element.tag} = #{key.tag}") do
            if_else_block("#{key.tag} = #{TT_STRING}") do
              note "文字列の鍵は中身で照合する。スロットが違っても同じ鍵"
              compare_string_content(element.value, key.value)
              if_("#{str_flag} = 1") { line "#{scratch32} = Z6" }
            end
            if_("#{element.value} = #{key.value}") { line "#{scratch32} = Z6" }
            end_block
          end
        end
        dedent
        line "NEXT"
      end
    end

    # 見つかった位置の値スロットを Z7 に置く
    def hash_value_into_z
      line "Z7 = #{scratch32}"
      line "Z7 = Z7 * #{SLOT_WORDS} + Z#{Z_HASH_VALUES} + #{MemoryLayout::ARRAY_HEADER_WORDS}"
      slot_on(7)
    end

    # R[a] = R[a][R[a+1]] (ハッシュ)。無い鍵は Ruby と同じく nil
    def load_hash_index(ref, key)
      hash_slots_into_z(ref)
      find_hash_key(key)
      if_else_block("#{scratch32} < 0") do
        note "無い鍵は nil (Ruby と同じ)"
        set_slot_nil(ref)
      end
      element = hash_value_into_z
      line "#{ref.value} = #{element.value}"
      line "#{ref.tag} = #{element.tag}"
      end_block
    end

    # R[a][R[a+1]] = R[a+2] (ハッシュ)
    def store_hash_index(ref, key, value, heap_code)
      hash_slots_into_z(ref)
      find_hash_key(key)
      if_else_block("#{scratch32} >= 0") do
        note "既にある鍵は値だけ差し替える"
        element = hash_value_into_z
        line "#{element.value} = #{value.value}"
        line "#{element.tag} = #{value.tag}"
      end
      note "新しい鍵は鍵と値の両方の末尾に足す"
      if_("#{scratch32_b} >= #{layout.max_array_len}") do
        note "1 スロットの容量がいっぱい"
        vm_error(heap_code)
      end
      line "#{scratch32} = #{scratch32_b}"
      line "Z7 = #{scratch32}"
      line "Z7 = Z7 * #{SLOT_WORDS} + Z#{Z_HASH_KEYS} + #{MemoryLayout::ARRAY_HEADER_WORDS}"
      new_key = slot_on(7)
      line "#{new_key.value} = #{key.value}"
      line "#{new_key.tag} = #{key.tag}"
      element = hash_value_into_z
      line "#{element.value} = #{value.value}"
      line "#{element.tag} = #{value.tag}"
      line "Z8 = #{scratch32_b}"
      line "Z8 = Z8 + 1   ' 組の数を 1 増やす"
      line "#{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z#{Z_HASH_KEYS} = Z8"
      line "#{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z#{Z_HASH_VALUES} = Z8"
      end_block
    end

    # --- ブロックと上位の変数 ---

    # R[a] = 子 irep b から作ったブロック (OP_BLOCK)
    #
    # メソッドと違い、ブロックは外側のローカル変数を読み書きします。そのため
    # 本体の irep だけでなく **定義元のフレーム**も覚えておきます。
    # 値スロットは 2 ワードあるので下位に irep、上位にフレーム番号を入れます。
    def load_block(name, child_name, error_code)
      child_irep_into(scratch_lo, child_name, error_code)
      dest = reg_slot(name)
      line "#{dest.word(0)} = #{scratch_lo}   ' 本体の irep"
      line "#{dest.word(1)} = #{current_frame_expr}   ' 定義元のフレーム"
      line "#{dest.tag} = #{TT_PROC}"
    end

    # 実行中のフレーム番号。トップレベルなら FRAME_NONE
    def current_frame_expr
      line "Z4 = #{MemoryLayout::FRAME_NONE}"
      if_("#{state(layout.frame_sp_addr)} > 0") do
        line "Z4 = #{state(layout.frame_sp_addr)} - 1"
      end
      "Z4"
    end

    # 上位の変数の入っているレジスタ窓を Z6 に求める (OP_GETUPVAR / OP_SETUPVAR)
    #
    # オペランド c は遡る段数です。フレームの「定義元」を c 回辿ります。
    # 辿り切る前に鎖が尽きたらエラーですが、**FOR の中で BREAK すると FOR を
    # 抜けるだけ**なので、印を立てておいて外で判定します。
    def upvar_base(level_name, error_code)
      if_("#{state(layout.frame_sp_addr)} = 0") do
        note "トップレベルには外側が無い"
        vm_error(error_code)
      end
      note "定義元のフレームを #{level_name} 段たどる"
      line "Z3 = #{top_frame_expr}"
      line "Z4 = #{layout.device_name}#{MemoryLayout::FRAME_OUTER}:Z3"
      line "#{scratch_lo} = 0   ' 鎖が尽きた印"
      if_("#{operand(level_name)} > 0") do
        line "FOR Z5 = 1 TO #{operand(level_name)}"
        indent
        if_else_block("Z4 = #{MemoryLayout::FRAME_NONE}") { line "#{scratch_lo} = 1" }
        line "Z3 = #{frame_expr('Z4')}"
        line "Z4 = #{layout.device_name}#{MemoryLayout::FRAME_OUTER}:Z3"
        end_block
        dedent
        line "NEXT"
      end
      if_("#{scratch_lo} <> 0") do
        note "指定された段数だけ遡れなかった"
        vm_error(error_code)
      end

      note "たどり着いたフレームのレジスタ窓。FRAME_NONE ならトップレベル"
      line "Z6 = #{layout.offset_of(layout.reg_file_base)}"
      if_("Z4 <> #{MemoryLayout::FRAME_NONE}") do
        line "Z3 = #{frame_expr('Z4')}"
        line "Z6 = #{layout.device_name}#{MemoryLayout::FRAME_OWN_BASE}:Z3"
      end
    end

    # R[a] = 外側の R[b] (OP_GETUPVAR)
    def load_upvar(name, index_name, level_name, error_code)
      upvar_base(level_name, error_code)
      src = slot_ref([:upvar, name], "#{operand(index_name)} * #{SLOT_WORDS}",
                     "Z6 + Z#{Z_INSTANCE}", z: Z_VALUE)
      dest = reg_slot(name)
      line "#{dest.value} = #{src.value}"
      line "#{dest.tag} = #{src.tag}"
    end

    # 外側の R[b] = R[a] (OP_SETUPVAR)
    def store_upvar(name, index_name, level_name, error_code)
      src = reg_slot(name)
      upvar_base(level_name, error_code)
      dest = slot_ref([:upvar, name], "#{operand(index_name)} * #{SLOT_WORDS}",
                      "Z6 + Z#{Z_INSTANCE}", z: Z_VALUE)
      line "#{dest.value} = #{src.value}"
      line "#{dest.tag} = #{src.tag}"
    end

    # 実行中の irep を切り替える。レジスタ窓が領域に収まるかも見る
    def switch_to_irep(index_expr, depth_code)
      line "#{state(layout.cur_irep_addr)} = #{index_expr}"
      load_irep_state("#{index_expr} * #{MemoryLayout::IREP_TABLE_STRIDE} + " \
                      "#{irep_table_offset}")
      note "レジスタ窓が領域からはみ出さないこと"
      line "#{scratch_lo} = #{state(layout.reg_base_addr)} + " \
           "#{state(layout.nregs_addr)} * #{SLOT_WORDS}"
      if_("#{scratch_lo} > #{layout.offset_of(layout.reg_slot_addr(layout.max_regs))}") do
        vm_error(depth_code)
      end
    end

    # メソッド本体の入口 (OP_ENTER)
    #
    # aspec は 24 ビットで、16 ビットの #{layout.device_name} には収まりません。
    # そのため上位バイトを operand a、下位 2 バイトを operand b に分けて持ちます
    # (fetch_u24 を参照)。必須引数の数は `aspec >> 18` で、これは上位バイトを
    # 4 で割った値と同じです。残りのビットが立っていれば省略可能引数・可変長・
    # キーワードのいずれかで、いずれも未対応です。
    def enter_method(name, error_code)
      note "必須引数の数 = aspec >> #{ASPEC_REQ_SHIFT}。上位バイトを 4 で割った値と同じ"
      line "Z3 = #{operand(name)} / 4"
      if_("#{operand(name)} <> Z3 * 4") do
        note "必須引数以外の指定 (省略可能・可変長・キーワード) は未対応"
        vm_error(error_code)
      end
      if_("#{operand(:b)} <> 0") { vm_error(error_code) }

      note "ブロックは引数の数を検査しない。Ruby は足りなければ nil、余れば捨てる"
      note "(引数を書かないブロックでも times は 1 個渡す)"
      line "Z4 = 0"
      if_("#{state(layout.frame_sp_addr)} > 0") do
        line "Z5 = #{top_frame_expr}"
        if_("#{layout.device_name}#{MemoryLayout::FRAME_KIND}:Z5 >= " \
            "#{MemoryLayout::FRAME_KIND_ITERATE}") do
          line "Z4 = 1"
        end
      end
      if_("Z4 = 0") do
        if_("#{state(layout.call_argc_addr)} <> Z3") do
          note "実引数の数が定義と違う"
          vm_error(error_code)
        end
      end

      note "引数の後ろのレジスタを空にする (未代入のローカル変数は偽になる)"
      note "受け取れなかった引数も空になる (Ruby の nil に相当)"
      if_("#{state(layout.call_argc_addr)} < Z3") do
        line "Z3 = #{state(layout.call_argc_addr)}"
      end
      line "Z4 = (Z3 + 1) * #{SLOT_WORDS} + #{reg_offset}"
      line "Z5 = #{state(layout.nregs_addr)} * #{SLOT_WORDS} + #{reg_offset} - 1"
      if_("Z4 <= Z5") do
        line "FOR Z6 = Z4 TO Z5"
        indent
        line "#{indexed_base}:Z6 = 0"
        dedent
        line "NEXT"
      end
    end

    # 呼び出し元へ戻る (OP_RETURN)
    #
    # 反復のフレームなら「戻る」のではなく **次の回に入り直します**。
    # VM は再帰できないため、繰り返しはここで組み立てます。
    def return_from_method(name)
      if_else_block("#{state(layout.frame_sp_addr)} = 0") do
        note "トップレベルの return は VM 停止"
        vm_finish
      end
      line "Z3 = #{top_frame_expr}"
      if_else_block("#{layout.device_name}#{MemoryLayout::FRAME_KIND}:Z3 >= " \
                    "#{MemoryLayout::FRAME_KIND_ITERATE}") do
        advance_iteration
      end
      note "R[a] を R[0] へ写す。R[0] は呼んだ側の R[a] と同じ場所なので"
      note "これで戻り値が呼び出し元から見える位置に入る"
      src = reg_slot(name)
      dest = slot_ref([:reg_self, name], "0", reg_offset, z: Z_SECONDARY)
      line "#{dest.value} = #{src.value}"
      line "#{dest.tag} = #{src.tag}"
      pop_frame
      end_block
      end_block
    end

    # 反復のフレーム。次の回があれば入り直し、無ければ抜ける
    def advance_iteration
      line "#{scratch32} = #{layout.device_name}#{MemoryLayout::FRAME_INDEX}.L:Z3 + 1"
      if_else_block("#{scratch32} <= #{layout.device_name}#{MemoryLayout::FRAME_LIMIT}.L:Z3") do
        note "次の回。PC を 0 に戻し、ブロックの引数を更新するだけ"
        note "irep もレジスタ窓もそのまま使い回す"
        line "#{layout.device_name}#{MemoryLayout::FRAME_INDEX}.L:Z3 = #{scratch32}"
        set_block_argument
        line "#{pc} = 0"
      end
      note "反復の終わり。R[0] にはレシーバが残っており、それが呼び出しの値になる"
      pop_frame
      end_block
    end

    # ブロックに渡す値と引数の数を書く
    #
    # 何を渡すかはフレームの種別で決まります。times / upto は添字、a.each は
    # その位置の要素、h.each は鍵と値です。レシーバは R[0] に残っています。
    # Z3 は呼ぶ側がフレームを指したままにしています。
    #
    # **Z6 は使えません。** enter_iteration が移り先の irep を載せています。
    #
    # **引数の数もここで書きます。** 反復の途中でユーザー定義メソッドを呼ぶと
    # call_argc がその引数の数で上書きされ、次の回の OP_ENTER が引数の後ろだと
    # 思った位置からレジスタを消してブロックの引数を壊すためです。
    # 再突入 (OP_RETURN) からも呼ばれるので、ここで書けば毎回正しくなります。
    def set_block_argument
      line "Z2 = #{SLOT_WORDS} + #{reg_offset}"
      argument = slot_on(2)
      element = slot_on(Z_ARRAY_ELEMENT)
      chain_head(true, "#{frame_kind} = #{MemoryLayout::FRAME_KIND_HASH_EACH}")
      indent
      note "h.each は鍵と値を渡す。レシーバのハッシュは R[0] に残っている"
      line "Z4 = 0 + #{reg_offset}"
      receiver = slot_on(4)
      pool_element_into_z(receiver.word(0))
      line "#{argument.value} = #{element.value}"
      line "#{argument.tag} = #{element.tag}"
      line "Z2 = 2 * #{SLOT_WORDS} + #{reg_offset}   ' R[2] に値"
      pool_element_into_z(receiver.word(1))
      line "#{argument.value} = #{element.value}"
      line "#{argument.tag} = #{element.tag}"
      line "#{state(layout.call_argc_addr)} = 2"
      dedent
      chain_head(false, "#{frame_kind} = #{MemoryLayout::FRAME_KIND_EACH}")
      indent
      note "a.each はその位置の要素を渡す。レシーバの配列は R[0] に残っている"
      line "Z4 = 0 + #{reg_offset}"
      pool_element_into_z("#{layout.device_name}#{SLOT_VALUE_OFFSET}.L:Z4")
      line "#{argument.value} = #{element.value}"
      line "#{argument.tag} = #{element.tag}"
      line "#{state(layout.call_argc_addr)} = 1"
      dedent
      line "ELSE"
      indent
      note "times / upto は添字を渡す"
      line "#{argument.value} = #{scratch32}"
      line "#{argument.tag} = #{TT_INTEGER}"
      line "#{state(layout.call_argc_addr)} = 1"
      dedent
      line "END IF"
    end

    # 実行中のフレームの種別 (Z3 がそのフレームを指していること)
    def frame_kind = "#{layout.device_name}#{MemoryLayout::FRAME_KIND}:Z3"

    # スロット番号の式から、今の反復位置にある要素の先頭を Z5 に置く
    def pool_element_into_z(slot_number)
      line "Z7 = #{slot_number}   ' スロット番号"
      line "Z7 = Z7 * #{layout.array_slot_words} + #{block_offset(layout.array_pool_base)}"
      line "Z#{Z_ARRAY_ELEMENT} = #{scratch32}"
      line "Z#{Z_ARRAY_ELEMENT} = Z#{Z_ARRAY_ELEMENT} * #{SLOT_WORDS} + Z7 + " \
           "#{MemoryLayout::ARRAY_HEADER_WORDS}"
    end

    # 積んであるフレームから PC・irep・レジスタ窓を復元する
    def pop_frame
      line "#{state(layout.frame_sp_addr)} = #{state(layout.frame_sp_addr)} - 1"
      note "外した段がそのまま戻り先。減らした後なので top_frame_expr ではない"
      line "Z3 = #{frame_expr(state(layout.frame_sp_addr))}"
      line "#{pc} = #{layout.device_name}#{MemoryLayout::FRAME_RETURN_PC}:Z3"
      line "Z5 = #{layout.device_name}#{MemoryLayout::FRAME_RETURN_IREP}:Z3"
      line "#{state(layout.reg_base_addr)} = " \
           "#{layout.device_name}#{MemoryLayout::FRAME_RETURN_BASE}:Z3"
      line "#{state(layout.cur_irep_addr)} = Z5"
      load_irep_state("Z5 * #{MemoryLayout::IREP_TABLE_STRIDE} + #{irep_table_offset}")
    end

    # index 段目のフレームを指す式
    def frame_expr(index)
      "#{index} * #{MemoryLayout::FRAME_WORDS} + " \
        "#{layout.offset_of(layout.frame_stack_base)} + Z#{Z_INSTANCE}"
    end

    # 積んである一番上のフレーム = 実行中のフレームを指す式 (frame_sp - 1 段目)
    def top_frame_expr = frame_expr("(#{state(layout.frame_sp_addr)} - 1)")

    # --- 反復 ---

    # R[a].メソッド(R[a+1]..) { ブロック } (OP_SENDB)
    #
    # `3.times do |i| ... end` は OP_SENDB ですが、繰り返すのは `Integer#times`
    # の側です。VM は再帰できないため、反復フレームに「今何回目か」と「上限」を
    # 持たせ、ブロックの OP_RETURN で次の回に入り直します。
    def send_block_method(name, sym_name, argc_name, unknown_code, type_code,
                          block_code, depth_code)
      method_table_lookup(sym_name)
      if_("Z4 <> #{SYMBOL_KIND_METHOD}") { vm_error(unknown_code) }
      note "ブロックを取るメソッドはレシーバの型で並んでいるため連続していない"
      line "Z6 = 0"
      BLOCK_METHODS.each { |code| if_("Z5 = #{code}") { line "Z6 = 1" } }
      if_("Z6 = 0") do
        note "ブロックを取らないメソッドにブロックを渡した"
        vm_error(unknown_code)
      end
      if_("#{operand(argc_name)} <> Z8") { vm_error(unknown_code) }

      recv = reg_slot(name)
      check_receiver_type(recv, type_code)

      note "ブロックは引数の後ろ R[a + 引数の数 + 1] にある"
      block = slot_ref([:block, name],
                       "(#{operand(name)} + #{operand(argc_name)} + 1) * #{SLOT_WORDS}",
                       reg_offset, z: Z_VALUE)
      if_("#{block.tag} <> #{TT_PROC}") { vm_error(block_code) }

      iteration_range(name, recv, type_code)
      if_("#{scratch32} <= #{scratch32_b}") do
        enter_iteration(name, argc_name, depth_code)
      end
      note "1 回も回らないときはレシーバがそのまま呼び出しの値になる"
    end

    # 反復の範囲を scratch32 (現在値) と scratch32_b (上限) に置く
    def iteration_range(name, recv, type_code)
      line "IF Z5 = #{METHOD_TIMES} THEN"
      indent
      note "n.times は 0 から n-1 まで"
      line "#{scratch32} = 0"
      line "#{scratch32_b} = #{recv.value} - 1"
      dedent
      line "ELSE IF Z5 = #{METHOD_EACH} THEN"
      indent
      note "a.each / h.each は 0 から要素数-1 まで"
      note "ハッシュは組の数。どちらも Z5 (メソッド番号) を壊さない方で読む"
      if_else_block("#{recv.tag} = #{TT_HASH}") { hash_keys_into_z(recv) }
      array_slot_into_z(recv)
      end_block
      line "#{scratch32} = 0"
      line "#{scratch32_b} = #{scratch32_b} - 1"
      dedent
      line "ELSE"
      indent
      note "a.upto(b) は a から b まで"
      limit = reg_next_slot(name)
      if_("#{limit.tag} <> #{TT_INTEGER}") { vm_error(type_code) }
      line "#{scratch32} = #{recv.value}"
      line "#{scratch32_b} = #{limit.value}"
      end_block
    end

    # 反復フレームを積み、ブロックの本体へ移る
    def enter_iteration(name, argc_name, depth_code)
      push_frame(depth_code, "#{operand(name)} * #{SLOT_WORDS}",
                 outer: MemoryLayout::FRAME_NONE,
                 kind: MemoryLayout::FRAME_KIND_ITERATE)
      if_("Z5 = #{METHOD_EACH}") do
        note "each はブロックに添字ではなく要素を渡す"
        note "ハッシュは鍵と値の 2 つを渡すので種別を分ける"
        line "Z4 = 0 + #{reg_offset}   ' 窓をずらした後の R[0] がレシーバ"
        if_else_block("#{slot_on(4).tag} = #{TT_HASH}") do
          line "#{frame_kind} = #{MemoryLayout::FRAME_KIND_HASH_EACH}"
        end
        line "#{frame_kind} = #{MemoryLayout::FRAME_KIND_EACH}"
        end_block
      end
      note "窓をずらした後、ブロックは R[引数の数 + 1] にある"
      line "Z2 = (#{operand(argc_name)} + 1) * #{SLOT_WORDS} + #{reg_offset}"
      line "Z6 = #{layout.device_name}#{SLOT_VALUE_OFFSET}:Z2       ' 本体の irep"
      line "Z7 = #{layout.device_name}#{SLOT_VALUE_OFFSET + 1}:Z2   ' 定義元のフレーム"
      note "反復の状態と定義元をフレームに書く (Z3 は push_frame が指したまま)"
      line "#{layout.device_name}#{MemoryLayout::FRAME_OUTER}:Z3 = Z7"
      line "#{layout.device_name}#{MemoryLayout::FRAME_INDEX}.L:Z3 = #{scratch32}"
      line "#{layout.device_name}#{MemoryLayout::FRAME_LIMIT}.L:Z3 = #{scratch32_b}"
      note "渡す値と引数の数はどちらもフレームの種別で決まる。まとめて書く"
      set_block_argument
      switch_to_irep("Z6", depth_code)
      line "#{pc} = 0"
    end

    # 反復を打ち切って R[a] を返す (OP_BREAK)
    def break_from_block(name, block_code)
      if_("#{state(layout.frame_sp_addr)} = 0") do
        note "反復の外での break"
        vm_error(block_code)
      end
      line "Z3 = #{top_frame_expr}"
      if_("#{layout.device_name}#{MemoryLayout::FRAME_KIND}:Z3 < " \
          "#{MemoryLayout::FRAME_KIND_ITERATE}") do
        vm_error(block_code)
      end
      note "break の値を R[0] へ。R[0] は呼んだ側の R[a] と同じ場所"
      src = reg_slot(name)
      dest = slot_ref([:reg_self, name], "0", reg_offset, z: Z_SECONDARY)
      line "#{dest.value} = #{src.value}"
      line "#{dest.tag} = #{src.tag}"
      pop_frame
    end

    # --- 組み込みメソッド ---
    #
    # 呼び出しフレームは作りません。引数は R[a+1] から連続して並び、結果は
    # R[a] に返るため、その場で計算して置き換えるだけで済みます。
    #
    # メソッド名はホスト側で番号に解決してシンボル表に載せてあります。
    # VM は文字列を持たず、整数の分岐だけで振り分けます。

    # R[a] = R[a].メソッド(R[a+1])
    def send_method(name, sym_name, argc_name, unknown_code, type_code, zero_code, heap_code)
      method_table_lookup(sym_name)
      if_("Z4 <> #{SYMBOL_KIND_METHOD}") do
        note "メソッド名でないシンボルへの呼び出し"
        vm_error(unknown_code)
      end
      builtin_dispatch(name, argc_name, unknown_code, type_code, zero_code, heap_code)
    end

    # Z5 (メソッド番号) と Z8 (引数の数) を読んだ後の共通部分
    def builtin_dispatch(name, argc_name, unknown_code, type_code, zero_code, heap_code)
      if_("#{operand(argc_name)} <> Z8") do
        note "引数の数が定義と違う"
        note "オペランドは位置引数とキーワード引数の数を4ビットずつ詰めたもの。"
        note "普通の呼び出しでは引数の数と一致し、スプラットやキーワード付きは弾かれる"
        vm_error(unknown_code)
      end

      dest = reg_slot(name)
      rhs = reg_next_slot(name)

      check_receiver_type(dest, type_code)

      first = true
      BUILTIN_PLAIN_METHODS.each_key do |code|
        chain_head(first, "Z5 = #{code}")
        first = false
        indent
        note METHOD_NAMES.fetch(code)
        method_body(code, dest, rhs, type_code, zero_code, heap_code)
        dedent
      end
      line "ELSE"
      indent
      note "未対応のメソッド (ブロックを取るメソッドをブロック無しで呼んだ場合も含む)"
      vm_error(unknown_code)
      dedent
      line "END IF"
    end

    # メソッド番号からレシーバに要求される型を検査する
    #
    # 番号もタグも連続した区分に並べてあるので、範囲比較だけで済みます。
    # 区分の並びは METHOD_RECEIVER_GROUPS。**最後の区分は上限が要りません。**
    def check_receiver_type(recv, type_code)
      note "メソッド番号の区分ごとにレシーバのタグの範囲を見る (METHOD_RECEIVER_GROUPS)"
      note "#{METHOD_NUMERIC_MIN} 未満 (!= と !) はどの型でも呼べる"
      if_("Z5 >= #{METHOD_NUMERIC_MIN}") do
        first = true
        METHOD_RECEIVER_GROUPS.each do |max_code, tag_min, tag_max, label|
          if max_code
            chain_head(first, "Z5 <= #{max_code}")
          else
            line "ELSE"
          end
          first = false
          indent
          note "#{label} (タグ #{tag_min}#{tag_min == tag_max ? '' : "-#{tag_max}"})"
          if tag_min == tag_max
            if_("#{recv.tag} <> #{tag_min}") { vm_error(type_code) }
          else
            if_("#{recv.tag} < #{tag_min}") { vm_error(type_code) }
            if_("#{recv.tag} > #{tag_max}") { vm_error(type_code) }
          end
          dedent
        end
        line "END IF"
      end
    end

    # --- 真偽判定 ---
    #
    # Ruby で偽なのは nil と false だけ。0 も空文字列も真。
    # タグの並び順がそのまま境界になっている (TT_FALSY_MAX 以下が偽)。

    def if_truthy(name, &block) = if_("#{reg_tag(name)} > #{TT_FALSY_MAX}", &block)
    def if_falsy(name, &block)  = if_("#{reg_tag(name)} <= #{TT_FALSY_MAX}", &block)
    def if_nil(name, &block)    = if_("#{reg_tag(name)} = #{TT_NIL}", &block)

    # 16ビットオペランドを符号付きとして解釈する
    # EM は16ビット符号なしのため引き算しても同じビット列だが、
    # PC への加算が16ビットの剰余演算になることで後方ジャンプが成立する
    def normalize_signed16(name)
      var = operand(name)
      if_("#{var} >= 32768") { line "#{var} = #{var} - 65536" }
    end

    def jump_relative(name)
      line "#{pc} = #{pc} + #{operand(name)}"
    end

    # 累計実行命令数を 1 増やす
    #
    # 命令ごとに走るので、費用がそのままスキャンタイムに乗ります。
    # `EM3.L:Z9 = EM3.L:Z9 + 1` と書かず INC を使うのはこのためです。
    def count_step
      line "INC(#{state_long(layout.step_count_addr)})   ' 累計実行命令数"
    end

    def vm_finish
      line "#{status} = #{VM_FINISHED}"
      line "BREAK"
    end

    def vm_error(code)
      line "#{status} = #{VM_ERROR}"
      line "#{error} = #{code}"
      line "BREAK"
    end

    # --- VM 状態・スクラッチ ---

    def pc     = state(layout.pc_addr)
    def status = state(layout.status_addr)
    def opcode = state(layout.current_opcode_addr)
    def error  = state(layout.error_addr)

    def scratch_lo  = state(layout.temp32_addr)
    def scratch_hi  = state(layout.temp32_addr + 1)
    def scratch32   = state_long(layout.temp32_addr)
    def scratch32_b = state_long(layout.temp32_b_addr)

    # 2つ目のスクラッチを実数として見たもの (デバイス書き込みの型合わせ用)
    def scratch_float = "#{layout.device_name}#{layout.offset_of(layout.temp32_b_addr)}.F:Z#{Z_INSTANCE}"

    # --- オペランドフェッチ (命令形式から生成) ---

    def fetch_operands(sizes)
      sizes.each_with_index do |bytes, i|
        target = operand(OPERAND_NAMES[i])
        case bytes
        when 1 then fetch_byte(target)
        when 2 then fetch_u16(target)
        else        fetch_u24(target)
        end
      end
    end

    # --- デバイスアクセス ---

    # デバイスマッピングテーブルから type / address / access_type / 族フラグを読む
    #
    # Z5 = 種別, Z6 = アドレス, Z8 = アクセス幅, Z1 = デバイス族フラグ
    def device_table_lookup(name)
      note "シンボル表参照 (#{DEVICE_TABLE_STRIDE}ワード/エントリ)"
      line "Z3 = #{operand(name)} * #{DEVICE_TABLE_STRIDE} + #{symbols_offset}"
      line "Z4 = Z3 + 1"
      line "Z5 = #{fixed_indexed_base}:Z3"
      line "Z6 = #{fixed_indexed_base}:Z4"
      line "Z7 = Z3 + 2"
      line "Z8 = #{fixed_indexed_base}:Z7"
      line "Z7 = Z3 + #{DEVICE_TABLE_KIND_OFFSET}"
      line "Z1 = #{fixed_indexed_base}:Z7   ' シンボル種別"
    end

    # デバイス族の参照値をスロットに置く ($DM を読んだとき)
    #
    # 種別と幅を1ワードに詰める。予備ワードを使うと OP_MOVE が
    # 4ワード目まで複製する必要が出るため。
    def assign_device_ref(slot)
      note "デバイス族。読み書きせず参照値を作る ($DM[i] の $DM の部分)"
      line "#{slot.word(0)} = Z6   ' ベースアドレス"
      line "#{slot.word(1)} = Z5 + Z8 * #{DEVICE_REF_ACCESS_SCALE}   ' 種別 + 幅"
      line "#{slot.tag} = #{TT_DEVICE}"
    end

    # デバイス参照 + 添字から Z5 / Z6 / Z8 を組み立てる
    #
    # device_table_lookup と同じ役割を、テーブルではなくレジスタの値から行う。
    # これで device_dispatch をそのまま使い回せる。
    def device_ref_lookup(ref, index_value, error_code)
      note "デバイス参照から種別・幅・アドレスを取り出す"
      line "Z8 = #{ref.word(1)} / #{DEVICE_REF_ACCESS_SCALE}   ' アクセス幅"
      line "Z5 = #{ref.word(1)} - Z8 * #{DEVICE_REF_ACCESS_SCALE}   ' デバイス種別"
      note "アドレス = ベース + 添字。範囲外は黙って別の場所を読み書きしてしまうため弾く"
      line "#{scratch32} = #{ref.word(0)} + #{index_value}"
      if_else_block("#{scratch32} >= 0") do
        if_else_block("#{scratch32} <= 65535") { line "Z6 = #{scratch32}" }
        vm_error(error_code)
        end_block
      end
      vm_error(error_code)
      end_block
    end

    # デバイス種別 × アクセス幅の分岐を生成する
    def device_dispatch(mode, slot:, error_code:)
      note "デバイスタイプ別#{mode == :read ? '読み取り' : '書き込み'}"
      note "ワードデバイス (EM, DM, ZF): Z8 (access_type) で幅を選ぶ"
      ACCESS_BRANCHES.each { |value, sfx| note "  #{value}=.#{sfx}(#{ACCESS_NAMES.fetch(value)})" }
      note "  それ以外=.#{ACCESS_DEFAULT_SUFFIX}(#{ACCESS_NAMES.fetch(ACCESS_S)}/既定)"
      if mode == :read
        note "ビットデバイス (R, MR, B, LR, T, C): ON→true, OFF→false"
        note "  整数の 1/0 ではなく真偽値。0 は Ruby では真なので、"
        note "  整数にすると if $MR10 が常に成立してしまう"
      else
        note "ビットデバイス (R, MR, B, LR, T, C): 非0→ON, 0→OFF"
        note "  true=1 / false=nil=0 なので値だけで判定できる"
      end

      first = true
      WORD_DEVICES.each do |type, name|
        chain_head(first, "Z5 = #{type}")
        first = false
        indent
        word_device_body(mode, name, slot, type)
        dedent
      end

      # ビットデバイスは幅サフィックスの有無で意味が変わる。
      # 無しなら個別ビット、有りなら整数 (MR 等はビット列、T/C は現在値)。
      BIT_DEVICES.each do |type, name, set_res|
        chain_head(first, "Z5 = #{type}")
        first = false
        indent
        if_else_block("Z8 = #{ACCESS_BIT}") { bit_device_body(mode, name, slot, set_res) }
        word_device_body(mode, name, slot, type)
        end_block
        dedent
      end

      line "ELSE"
      indent
      vm_error(error_code)
      dedent
      line "END IF"
    end

    private

    # タグが数値 (整数か実数) かどうかの条件式
    # 型タグが数値かどうかを Z に 0/1 で置く
    #
    # 数値は #{TT_INTEGER} と #{TT_FLOAT} の 2 つだけです。「#{TT_INTEGER} 以上」で
    # 済ませていたころは、その後ろのタグ (シンボル・配列など) まで数値として
    # 通っていました。KV スクリプトに AND が無いため入れ子の IF で判定します。
    def numeric_flag_into(z, tag)
      line "Z#{z} = 0"
      if_("#{tag} >= #{TT_INTEGER}") do
        if_("#{tag} <= #{TT_FLOAT}") { line "Z#{z} = 1" }
      end
      "Z#{z} = 1"
    end

    # 整数どうしの除算 (Ruby と同じ切り下げ、0除算はエラー停止)
    #
    # KV スクリプトの / は 0 方向へ切り捨てる (-7 / 2 = -3、実機で確認済み)。
    # Ruby は切り下げ (-4) なので、符号が異なり余りが出る場合に 1 を引く。
    def integer_div(dest, lhs, rhs, error_code)
      if_else_block(cmp(:ne, rhs, const(0))) do
        note "Ruby の整数除算は切り下げ。KV の / は0方向へ切り捨てるため補正する"
        line "#{scratch32} = #{lhs}       ' 被除数を退避"
        line "#{dest.value} = #{binop(:div, lhs, rhs)}"
        line "#{scratch32_b} = #{scratch32} - #{dest.value} * #{rhs}   ' 余り"
        if_("#{scratch32_b} <> 0") do
          note "符号が異なるときだけ切り下げになる"
          if_else_block("#{scratch32} < 0") do
            if_("#{rhs} > 0") { line "#{dest.value} = #{dest.value} - 1" }
          end
          if_("#{rhs} < 0") { line "#{dest.value} = #{dest.value} - 1" }
          end_block
        end
        line "#{dest.tag} = #{TT_INTEGER}"
      end
      vm_error(error_code)
      end_block
    end

    # 実数が絡む除算
    #
    # Ruby の 1.0 / 0 は Infinity で例外にならない。一方 KV スクリプトで
    # 0 除算を実行すると軽度エラー CR2012 が出て代入先も更新されない
    # (実機で確認済み)。そこで除数が 0 のときは除算を実行せず、
    # IEEE754 のビット列を直接書き込む。
    def float_div(dest, lhs, rhs)
      if_else_block(cmp(:ne, rhs, const(0))) do
        line "#{dest.float} = #{binop(:div, lhs, rhs)}"
      end
      note "0 除算。KV の / は CR2012 を出すため実行せず、"
      note "IEEE754 の無限大 / 非数のビット列を直接置く"
      note "代入先は被除数と同じレジスタなので、先に符号から上位ワードを決める。"
      note "被除数を書き換えてから符号を見ると、低位ワードを消した時点で"
      note "整数の 1-65535 が 0 になり、+Infinity が NaN になる"
      line "#{scratch_lo} = #{FLOAT_NAN_HI}   ' 既定は NaN (0.0 / 0.0)"
      if_("#{lhs} > 0") { line "#{scratch_lo} = #{FLOAT_POS_INF_HI}   ' +Infinity" }
      if_("#{lhs} < 0") { line "#{scratch_lo} = #{FLOAT_NEG_INF_HI}   ' -Infinity" }
      line "#{dest.word(0)} = 0"
      line "#{dest.word(1)} = #{scratch_lo}"
      end_block
      line "#{dest.tag} = #{TT_FLOAT}"
    end

    # --- 組み込みメソッドの本体 ---

    # シンボル表からメソッド番号・引数の数・種別を読む
    #
    # Z5 = メソッド番号, Z8 = 引数の数, Z4 = 種別
    # Z1 / Z2 は使わない。この後レジスタスロットの参照に使うため。
    def method_table_lookup(name)
      note "シンボル表参照 (#{DEVICE_TABLE_STRIDE}ワード/エントリ)"
      line "Z3 = #{operand(name)} * #{DEVICE_TABLE_STRIDE} + #{symbols_offset}"
      line "Z5 = #{fixed_indexed_base}:Z3   ' メソッド番号"
      line "Z7 = Z3 + 2"
      line "Z8 = #{fixed_indexed_base}:Z7   ' 引数の数"
      line "Z7 = Z3 + #{DEVICE_TABLE_KIND_OFFSET}"
      line "Z4 = #{fixed_indexed_base}:Z7   ' シンボル種別"
    end

    def method_body(code, dest, rhs, type_code, zero_code, heap_code)
      case code
      when METHOD_NE    then eq_into(dest, rhs, negate: true)
      when METHOD_NOT   then not_into(dest)
      when METHOD_MOD   then mod_into(dest, rhs, type_code, zero_code)
      when METHOD_ABS   then abs_into(dest)
      when METHOD_TO_I  then to_i_into(dest)
      when METHOD_TO_F  then to_f_into(dest)
      when METHOD_FLOOR then floor_into(dest)
      when METHOD_ROUND then round_into(dest)
      when METHOD_BIT_AND then bit_op_into(dest, rhs, "AND", type_code)
      when METHOD_BIT_OR  then bit_op_into(dest, rhs, "OR", type_code)
      when METHOD_BIT_XOR then bit_op_into(dest, rhs, "XOR", type_code)
      when METHOD_BIT_NOT then bit_not_into(dest, type_code)
      when METHOD_SHIFT_R then shift_into(dest, rhs, false, type_code)
      when METHOD_LENGTH then length_into(dest)
      when METHOD_EMPTY_P then empty_into(dest)
      when METHOD_CONCAT then concat_into(dest, rhs, type_code, heap_code)
      when METHOD_PUSH   then push_into(dest, rhs, heap_code)
      when METHOD_KEY_P  then key_p_into(dest, rhs)
      when METHOD_KEYS   then hash_column_into(dest, Z_HASH_KEYS, heap_code)
      when METHOD_VALUES then hash_column_into(dest, Z_HASH_VALUES, heap_code)
      else raise ArgumentError, "組み込みメソッドの本体がありません (#{code})"
      end
    end

    # R[a].length / R[a].size。レシーバの型が区分に合うことは検査済み
    #
    # ハッシュの組の数は鍵の配列の見出しにあります。値スロットの読み方が
    # 配列と違う (下位ワードだけがスロット番号) ため、型で分けます。
    #
    # **文字列だけは見出しの数 (バイト数) をそのまま返しません。** Ruby の
    # `length` は文字数なので、切れ目を数えます。
    def length_into(dest)
      if_else_block("#{dest.tag} = #{TT_HASH}") { hash_keys_into_z(dest) }
      array_slot_into_z(dest)
      if_("#{dest.tag} = #{TT_STRING}") do
        note "文字列は文字数を返す。バイト数ではない"
        line "#{str_target} = #{STR_NO_TARGET}   ' 数えるだけ"
        scan_string_characters
        line "#{scratch32_b} = #{str_count}"
      end
      end_block
      line "#{dest.value} = #{scratch32_b}"
      line "#{dest.tag} = #{TT_INTEGER}"
    end

    # R[a].empty?
    #
    # 長さが 0 かどうかだけなので、**文字列でも切れ目を数える必要はありません。**
    # バイト数が 0 なら文字数も 0 です。
    def empty_into(dest)
      if_else_block("#{dest.tag} = #{TT_HASH}") { hash_keys_into_z(dest) }
      array_slot_into_z(dest)
      end_block
      if_else_block("#{scratch32_b} = 0") { assign_bool(dest, true) }
      assign_bool(dest, false)
      end_block
    end

    # R[a] << R[a+1]
    #
    # **整数なら左シフト、文字列なら中身を継ぎ足し、配列なら末尾に足します。**
    # Ruby と同じです。文字列と配列はレシーバ自身を返すので R[a] はそのまま。
    #
    # 区分の検査はタグ #{'%d'} から #{'%d'} までしか見ていません (整数と配列が
    # 離れているため)。実数とシンボルはここで弾きます。
    def concat_into(dest, rhs, type_code, heap_code)
      line "IF #{dest.tag} = #{TT_INTEGER} THEN"
      indent
      shift_into(dest, rhs, true, type_code)
      dedent
      line "ELSE IF #{dest.tag} = #{TT_STRING} THEN"
      indent
      note "文字列は中身を継ぎ足す"
      append_string_slots(dest, rhs, type_code, heap_code)
      dedent
      line "ELSE IF #{dest.tag} = #{TT_ARRAY} THEN"
      indent
      push_into(dest, rhs, heap_code)
      dedent
      line "ELSE"
      indent
      note "実数とシンボルは区分の範囲に入ってしまうのでここで弾く"
      vm_error(type_code)
      end_block
    end

    # R[a].key?(R[a+1])。鍵があるかどうかだけを返す
    def key_p_into(dest, rhs)
      hash_keys_into_z(dest)
      find_hash_key(rhs)
      if_else_block("#{scratch32} < 0") { assign_bool(dest, false) }
      assign_bool(dest, true)
      end_block
    end

    # R[a].keys / R[a].values
    #
    # Ruby と同じく新しい配列を返します。**プールを 1 スロット使う**ので、
    # ループの中で呼び続けると使い切ります。配列リテラルと同じ制約です。
    #
    # source_z は写す元の見出しが載っている Z (鍵か値のどちらか)。
    def hash_column_into(dest, source_z, heap_code)
      note "プールの空きスロットを取る。返さないので使い切ったら止まる"
      if_("#{state(layout.array_sp_addr)} >= #{layout.max_arrays}") { vm_error(heap_code) }
      hash_slots_into_z(dest)
      note "新しいスロットの見出し。組の数がそのまま要素数になる"
      line "Z2 = #{state(layout.array_sp_addr)} * #{layout.array_slot_words} + " \
           "#{block_offset(layout.array_pool_base)}"
      line "#{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z2 = #{scratch32_b}"
      note "写す。組の数 0 (空ハッシュ) では引き算もしない"
      if_("#{scratch32_b} > 0") do
        line "Z8 = #{scratch32_b}"
        line "Z8 = Z8 - 1"
        line "FOR Z6 = 0 TO Z8"
        indent
        line "Z7 = Z6 * #{SLOT_WORDS} + Z#{source_z} + #{MemoryLayout::ARRAY_HEADER_WORDS}"
        line "Z3 = Z6 * #{SLOT_WORDS} + Z2 + #{MemoryLayout::ARRAY_HEADER_WORDS}"
        copy_slot(from: 7, to: 3)
        dedent
        line "NEXT"
      end
      note "R[a] はハッシュから配列に変わる。値ワードを 32 ビットで書くので"
      note "上位に入っていた値の配列のスロット番号も消える"
      line "#{dest.value} = #{state(layout.array_sp_addr)}   ' スロット番号"
      line "#{dest.tag} = #{TT_ARRAY}"
      line "#{state(layout.array_sp_addr)} = #{state(layout.array_sp_addr)} + 1"
    end

    # R[a] << R[a+1] / R[a].push(R[a+1])
    #
    # Ruby はレシーバ自身を返すので、R[a] は配列のままにします。
    def push_into(dest, rhs, heap_code)
      array_slot_into_z(dest)
      if_("#{scratch32_b} >= #{layout.max_array_len}") do
        note "1 スロットの容量がいっぱい"
        vm_error(heap_code)
      end
      note "末尾に足して要素数を 1 増やす"
      line "#{scratch32} = #{scratch32_b}"
      element = array_element_into_z
      line "#{element.value} = #{rhs.value}"
      line "#{element.tag} = #{rhs.tag}"
      line "Z6 = #{scratch32_b}"
      line "#{layout.device_name}#{MemoryLayout::ARRAY_LENGTH}:Z#{Z_ARRAY_SLOT} = Z6 + 1"
    end

    # --- ビット演算 ---
    #
    # KV スクリプトは `AND` / `OR` / `XOR` / `NOT` をワードの演算子として書けます。
    # **条件式の連結には使えません** (そちらは入れ子の IF にしています)。
    # シフトは `SLA(元, 桁数, 先)` / `SRA(元, 桁数, 先)` の文です。
    #
    # 整数だけです。実数を渡すと止まります。ビット列に意味を持たせるのは
    # 整数のときだけで、実数のビット列を触っても使い道がありません。

    # R[a] = R[a] <演算> R[a+1] (& | ^)
    def bit_op_into(dest, rhs, operator, type_code)
      both_integers(dest, rhs, type_code) do
        line "#{dest.value} = #{dest.value} #{operator} #{rhs.value}"
      end
    end

    # R[a] = ~R[a]
    #
    # **KV にワードの `NOT` はありません。** 2 の補数から作ります。
    # `~x` は `-x - 1` なので、`NEG` で符号を反転してから 1 引きます。
    def bit_not_into(dest, type_code)
      if_("#{dest.tag} <> #{TT_INTEGER}") { vm_error(type_code) }
      emit_bit_not(dest.value, dest.value)
    end

    # target = ~source (`~x` = `-x - 1`)
    def emit_bit_not(target, source)
      line "#{target} = NEG(#{source})"
      line "#{target} = #{target} - 1   ' ~x = -x - 1"
    end

    # R[a] = R[a] << R[a+1] / R[a] >> R[a+1]
    #
    # **Ruby は桁数が負なら向きが逆になります** (`a << -1` は `a >> 1`)。
    # 32 桁以上ずらすと左は 0、右は符号で埋まります。そこまで合わせます。
    # 合わせないと `SLA` / `SRA` に範囲外の桁数が渡り、何が返るか分かりません。
    def shift_into(dest, rhs, left, type_code)
      both_integers(dest, rhs, type_code) do
        line "#{scratch32_b} = #{rhs.value}   ' 桁数"
        if_else_block("#{scratch32_b} < 0") do
          note "桁数が負なら向きが逆 (Ruby と同じ)"
          line "#{scratch32_b} = 0 - #{scratch32_b}"
          emit_shift(dest, !left)
        end
        emit_shift(dest, left)
        end_block
      end
    end

    # 桁数は scratch32_b。`SLA` / `SRA` は `結果 = SLA(元, 桁数)` の形
    #
    # 右シフトは**負の値をビット反転で挟みます**。Ruby の `>>` は符号を保ち
    # ますが、KV のシフトが論理シフトだと 0 で埋まって大きな正の数になります。
    # `~((~v) >> n)` は**論理でも算術でも同じ答え**になるので、どちらか
    # 分からないうちはこの形にしておきます (正の値では両者が一致するため、
    # 反転して正にしてからずらせばよい)。
    #
    # 左シフトは論理と算術で結果が同じなのでそのままです。
    def emit_shift(dest, left)
      if_else_block("#{scratch32_b} >= 32") do
        note "全部ずれる。左は 0、右は符号で埋まる"
        if left
          line "#{dest.value} = 0"
        else
          if_else_block("#{dest.value} < 0") { line "#{dest.value} = -1" }
          line "#{dest.value} = 0"
          end_block
        end
      end
      if left
        line "#{dest.value} = SLA(#{dest.value}, #{scratch32_b})"
      else
        if_else_block("#{dest.value} < 0") do
          note "負は反転して正にしてからずらし、戻す。符号が保たれる"
          emit_bit_not(scratch32, dest.value)
          line "#{scratch32} = SRA(#{scratch32}, #{scratch32_b})"
          emit_bit_not(dest.value, scratch32)
        end
        line "#{dest.value} = SRA(#{dest.value}, #{scratch32_b})"
        end_block
      end
      end_block
    end

    # 両方が整数のときだけ本体を出す。片方でも違えば止まる
    def both_integers(dest, rhs, type_code)
      if_("#{dest.tag} <> #{TT_INTEGER}") { vm_error(type_code) }
      if_("#{rhs.tag} <> #{TT_INTEGER}") { vm_error(type_code) }
      yield
      line "#{dest.tag} = #{TT_INTEGER}"
    end

    # !R[a]。偽なら true、それ以外は false
    def not_into(dest)
      if_else_block("#{dest.tag} > #{TT_FALSY_MAX}") { assign_bool(dest, false) }
      assign_bool(dest, true)
      end_block
    end

    # R[a] % R[a+1]。整数どうしのみ
    #
    # Ruby の % は商を切り下げた余りで、符号は除数に合います (-7 % 3 = 2)。
    # KV の / は 0 方向へ切り捨てるため、符号が違うときに除数を足して補正します。
    def mod_into(dest, rhs, type_code, zero_code)
      note "整数どうしのみ。実数の % は未対応"
      if_else_block("#{rhs.tag} = #{TT_INTEGER}") do
        if_else_block("#{dest.tag} = #{TT_INTEGER}") do
          integer_mod(dest, rhs, zero_code)
        end
        vm_error(type_code)
        end_block
      end
      vm_error(type_code)
      end_block
    end

    def integer_mod(dest, rhs, zero_code)
      if_else_block(cmp(:ne, rhs.value, const(0))) do
        line "#{scratch32} = #{dest.value}       ' 被除数を退避"
        line "#{dest.value} = #{binop(:div, dest.value, rhs.value)}   ' 0方向へ切り捨てた商"
        line "#{scratch32_b} = #{scratch32} - #{dest.value} * #{rhs.value}   ' 余り"
        if_("#{scratch32_b} <> 0") do
          note "符号が違うときだけ除数を足して符号を合わせる"
          if_else_block("#{scratch32} < 0") do
            if_("#{rhs.value} > 0") { line "#{scratch32_b} = #{scratch32_b} + #{rhs.value}" }
          end
          if_("#{rhs.value} < 0") { line "#{scratch32_b} = #{scratch32_b} + #{rhs.value}" }
          end_block
        end
        line "#{dest.value} = #{scratch32_b}"
        line "#{dest.tag} = #{TT_INTEGER}"
      end
      vm_error(zero_code)
      end_block
    end

    # 絶対値。型は変わらない
    def abs_into(dest)
      if_else_block("#{dest.tag} = #{TT_FLOAT}") do
        if_("#{dest.float} < 0") { line "#{dest.float} = 0 - #{dest.float}" }
      end
      if_("#{dest.value} < 0") { line "#{dest.value} = 0 - #{dest.value}" }
      end_block
    end

    # 実数→整数。整数はそのまま
    #
    # 同じスロットを .F で読んで .L で書くため、一度スクラッチに移します。
    def to_i_into(dest)
      if_("#{dest.tag} = #{TT_FLOAT}") do
        note "0 方向へ切り捨て (Ruby の Float#to_i と同じ)"
        line "#{scratch32} = #{dest.float}"
        line "#{dest.value} = #{scratch32}"
        line "#{dest.tag} = #{TT_INTEGER}"
      end
    end

    # 整数→実数。実数はそのまま
    def to_f_into(dest)
      if_("#{dest.tag} = #{TT_INTEGER}") do
        note "整数→実数。同じスロットを .L で読んで .F で書くためスクラッチを挟む"
        line "#{scratch_float} = #{dest.value}"
        line "#{dest.float} = #{scratch_float}"
        line "#{dest.tag} = #{TT_FLOAT}"
      end
    end

    # 切り下げ。整数はそのまま
    def floor_into(dest)
      if_("#{dest.tag} = #{TT_FLOAT}") do
        note "KV の実数→整数は 0 方向へ切り捨て。負で端数があるときだけ 1 引く"
        line "#{scratch32} = #{dest.float}"
        if_("#{dest.float} < 0") do
          if_("#{scratch32} <> #{dest.float}") { line "#{scratch32} = #{scratch32} - 1" }
        end
        line "#{dest.value} = #{scratch32}"
        line "#{dest.tag} = #{TT_INTEGER}"
      end
    end

    # 四捨五入。整数はそのまま
    def round_into(dest)
      if_("#{dest.tag} = #{TT_FLOAT}") do
        note "Ruby の round は 0 から遠い方へ丸める (2.5→3, -2.5→-3)"
        if_else_block("#{dest.float} >= 0") { line "#{scratch_float} = #{dest.float} + 0.5" }
        line "#{scratch_float} = #{dest.float} - 0.5"
        end_block
        line "#{scratch32} = #{scratch_float}"
        line "#{dest.value} = #{scratch32}"
        line "#{dest.tag} = #{TT_INTEGER}"
      end
    end

    # スロットに true / false を書く
    def assign_bool(slot, value)
      tag = value ? TT_TRUE : TT_FALSE
      line "#{slot.value} = #{TT_CANONICAL_VALUE.fetch(tag)}"
      line "#{slot.tag} = #{tag}"
    end

    # GETGV/SETGV はデバイステーブルが Z3-Z8 を占有するため、
    # レジスタアドレスには副オペランド用の Z を使う
    def global_reg_slot(name)
      slot_ref([:reg, name], "#{operand(name)} * #{SLOT_WORDS}", reg_offset, z: Z_SECONDARY)
    end

    # 値スロットの先頭アドレスを Z に設定し、タグと値の参照を返す
    # 同じスロットを同一命令内で複数回参照しても Z 設定は1度だけ出力する
    #
    # 型サフィックスはデバイス側に付ける (EM1.L:Z1)。
    # EM1:Z1.L と書くと .L がインデックスレジスタに結合し、
    # エラーにならないまま16ビットアクセスに退化する。
    def slot_ref(key, index_expr, base_expr, z: nil, device: layout.device_name)
      return @slot_cache[key] if @slot_cache.key?(key)

      z ||= key == [:reg, :a] ? Z_PRIMARY : Z_SECONDARY
      line "Z#{z} = #{index_expr} + #{base_expr}"
      @slot_cache[key] = Slot.new("#{device}#{SLOT_TYPE_OFFSET}:Z#{z}", z, device)
    end

    # バイトコードの現在位置を Z1 経由で読み、PC を1つ進める
    def read_bytecode_into(dest)
      line "Z1 = #{pc} + #{bytecode_offset}"
      line "#{dest} = #{fixed_indexed_base}:Z1"
      line "#{pc} = #{pc} + 1"
    end

    def fetch_byte(target) = read_bytecode_into(target)

    # 16ビットビッグエンディアン (上位バイトが先)
    def fetch_u16(target)
      note "16bit big-endian: hi byte, lo byte"
      read_bytecode_into("Z3")
      read_bytecode_into("Z4")
      line "#{target} = Z3 * 256 + Z4"
    end

    # 24ビットビッグエンディアン (OP_ENTER の aspec)
    #
    # #{layout.device_name} は16ビットなので 1 ワードに収まりません。上位バイトを
    # そのオペランドに、下位 2 バイトを次のオペランドに分けて置きます。
    # 使う側 (enter_method) はこの分け方を前提にしています。
    def fetch_u24(target)
      note "24bit big-endian。16ビットに収まらないため上位バイトと下位2バイトに分ける"
      read_bytecode_into(target)
      read_bytecode_into("Z3")
      read_bytecode_into("Z4")
      line "#{operand(:b)} = Z3 * 256 + Z4   ' aspec の下位2バイト"
    end

    def chain_head(first, cond)
      line(first ? "IF #{cond} THEN" : "ELSE IF #{cond} THEN")
    end

    def word_device_body(mode, name, slot, type)
      branches = ACCESS_BRANCHES
      branches = branches.reject { |value, _| value == ACCESS_F } if NO_FLOAT_DEVICES.include?(type)

      first = true
      branches.each do |value, suffix|
        chain_head(first, "Z8 = #{value}")
        first = false
        indent
        word_access(mode, name, suffix, slot)
        dedent
      end
      line "ELSE"
      indent
      word_access(mode, name, ACCESS_DEFAULT_SUFFIX, slot)
      dedent
      line "END IF"
    end

    # 1つのアクセス幅に対する読み書き
    #
    # 読み取りは幅に応じた型タグも書く。書き込みはあらかじめ用意した
    # 整数・実数のスクラッチを使うため、レジスタの型を再び見なくてよい。
    def word_access(mode, name, suffix, slot)
      device = "#{name}0.#{suffix}:Z6"
      float = suffix == "F"

      if mode == :read
        line "#{float ? slot.float : slot.value} = #{device}"
        line "#{slot.tag} = #{float ? TT_FLOAT : TT_INTEGER}"
      else
        line "#{device} = #{float ? scratch_float : scratch32}"
      end
    end

    # 書き込み用に、レジスタの値を必要な形へ変換する
    #
    # 実数レジスタを .S へ書くときは数値変換 (0方向へ切り捨て) が要り、
    # 整数レジスタを .F へ書くときは逆の変換が要る。ここで1度だけ済ませて
    # おけば、アクセス幅ごとの分岐でレジスタの型を見なくてよくなる。
    #
    # 【重要】両方の形を先に作ってはいけない。Infinity や NaN を整数へ変換すると
    # 浮動小数点フォーマット異常になるため、.F へ書くだけの場合に整数への変換を
    # 実行すると `$DM100F = 1.0 / 0` が PLC のエラーになる。
    def prepare_write_scratches(slot)
      note "レジスタの値を書き込み先の幅に合わせて変換する"
      note "使う側の形だけを作る。Infinity や NaN の整数変換は"
      note "浮動小数点フォーマット異常になるため、.F 書き込みでは行わない"
      if_else_block("Z8 = #{ACCESS_F}") do
        if_else_block("#{slot.tag} = #{TT_FLOAT}") { line "#{scratch_float} = #{slot.float}" }
        line "#{scratch_float} = #{slot.value}      ' 整数→実数"
        end_block
      end
      if_else_block("#{slot.tag} = #{TT_FLOAT}") do
        line "#{scratch32} = #{slot.float}      ' 実数→整数 (0方向へ切り捨て)"
      end
      line "#{scratch32} = #{slot.value}"
      end_block
      end_block
    end

    def bit_device_body(mode, name, slot, set_res)
      bit = "#{name}0:Z6"
      if mode == :read
        if_else_block(bit) { assign_bool(slot, true) }
        assign_bool(slot, false)
        end_block
      elsif set_res
        if_else_block("#{scratch32} <> 0") { line "SET(#{bit})" }
        line "RES(#{bit})"
        end_block
      else
        if_else_block("#{scratch32} <> 0") { line "#{bit} = 1" }
        line "#{bit} = 0"
        end_block
      end
    end
  end

  # vm_core.kvs を生成する
  #
  # generate は { ファイル名 => 内容 } を返します。現在は 1 ファイルですが、
  # KV Studio がスクリプトの大きさで変換できなくなった場合に分割できるよう
  # 複数ファイルを返せる形にしてあります。
  class KvsGenerator
    include VmConstants

    OUTPUT_NAME = "vm_core.kvs"
    INIT_NAME   = "vm_init.kvs"
    OUTPUT_DIR  = File.expand_path("../plc/keyence", __dir__)

    attr_reader :layout

    def initialize(opcodes = OpcodeTable.all, layout: MemoryLayout.default)
      @opcodes = opcodes
      @layout = layout
    end

    # デコード対象のオペコードを保持するデバイス
    def opcode_var = query.opcode

    # 行を出さずにデバイス式だけを尋ねるための emitter
    def query = @query ||= KvsEmitter.new(layout: layout)

    def generate
      { OUTPUT_NAME => build_source, INIT_NAME => build_init_source }
    end

    def source
      generate.fetch(OUTPUT_NAME)
    end

    def init_source
      generate.fetch(INIT_NAME)
    end

    # 生成結果をファイルに書き出す。書き換わったファイル名を返す
    def write!(dir = OUTPUT_DIR)
      generate.filter_map do |name, content|
        path = File.join(dir, name)
        next if File.exist?(path) && File.binread(path) == content.b

        File.binwrite(path, content)
        name
      end
    end

    private

    # リセットハンドラ (毎スキャン実行、RESET_REQ = 1 のインスタンスだけ動く)
    def build_init_source
      e = KvsEmitter.new(layout: layout)
      z = KvsEmitter::Z_PRIMARY

      e.note "======================================="
      e.note "faRuby VM - Reset Handler"
      e.note "======================================="
      e.note "【自動生成】このファイルを直接編集しないでください。"
      e.note "  生成: tools/kvs_generator.rb  (rake vm_core)"
      e.note ""
      e.note "毎スキャン実行。RESET_REQ = 1 のインスタンスについて"
      e.note "VM 状態とレジスタファイルを初期化します。"
      e.blank

      e.save_z_registers
      e.select_fixed_bank
      e.blank

      e.each_instance do
        e.blank
        e.line "IF #{e.state(layout.reset_req_addr)} = 1 THEN"
        e.blank
        e.indent
        e.line "#{e.pc} = 0      ' PC = 0"
        e.line "#{e.status} = #{VM_STOPPED}      ' STATUS = stopped"
        e.line "#{e.error} = 0      ' ERROR = none"
        e.line "#{e.state_long(layout.step_count_addr)} = 0    ' STEP_COUNT = 0"
        e.blank
        e.reset_to_top_irep
        e.blank
        e.note "レジスタファイルクリア " \
               "(ブロック先頭 +#{layout.offset_of(layout.reg_file_base)} から " \
               "#{layout.max_regs}スロット × #{SLOT_WORDS}ワード)"
        e.note "スロット先頭の型タグも 0 (TT_EMPTY) になる"
        e.line "FOR Z#{z} = #{e.block_offset(layout.reg_file_base)} " \
               "TO #{e.block_offset(layout.reg_slot_addr(layout.max_regs) - 1)}"
        e.indent
        e.line "#{e.indexed_base}:Z#{z} = 0"
        e.dedent
        e.line "NEXT"
        e.blank
        e.line "#{e.state(layout.reset_req_addr)} = 0     ' リセット要求クリア"
        e.dedent
        e.blank
        e.line "END IF"
        e.blank
      end

      e.blank
      e.restore_fixed_bank
      e.restore_z_registers
      "#{e.lines.join("\n")}\n"
    end

    def build_source
      e = KvsEmitter.new(layout: layout)
      emit_header(e)
      e.blank
      e.save_z_registers
      e.select_fixed_bank
      e.blank

      e.each_instance do
        e.blank
        e.line "IF #{e.status} = #{VM_RUNNING} THEN"
        e.blank
        e.indent
        e.line "FOR #{e.state(layout.loop_counter_addr)} = 1 TO #{e.state(layout.steps_per_cycle_addr)}"
        e.blank
        e.indent
        emit_fetch(e)
        emit_dispatch(e)
        emit_range_check(e)
        e.dedent
        e.line "NEXT"
        e.dedent
        e.blank
        e.line "END IF"
        e.blank
      end

      e.blank
      e.restore_fixed_bank
      e.restore_z_registers
      "#{e.lines.join("\n")}\n"
    end

    def emit_header(e)
      e.note "======================================="
      e.note "faRuby VM Core - Fetch/Decode/Execute"
      e.note "======================================="
      e.note "【自動生成】このファイルを直接編集しないでください。"
      e.note "  定義: tools/opcode_table.rb"
      e.note "  生成: tools/kvs_generator.rb  (rake vm_core)"
      e.note "  編集した場合 test_kvs_generator.rb が失敗します。"
      e.note ""
      e.note "#{layout.device_name} デバイスを使用。"
      e.note ""
      e.note "インスタンスごとに #{layout.instance_size} ワードのブロックを使います。"
      layout.instances.times do |i|
        block = layout.for_instance(i)
        e.note "  インスタンス#{i}  #{layout.device(block.origin)}-#{layout.device(block.block_last_addr)}"
      end
      e.note ""
      e.note "実行中のブロック先頭は Z#{KvsEmitter::Z_INSTANCE} に載っています。"
      e.note "ブロック内の位置はオフセットをインデックス修飾で足して指します。"
      e.note "どのインスタンスでも同じコードが動くのはこのためです。"
      e.note ""
      e.note "ブロック先頭からのオフセット:"
      e.note "  #{e.pc}#{' ' * 2}= PC (プログラムカウンタ)"
      e.note "  #{e.status}  = STATUS (0=停止, 1=実行中, 2=完了, 3=エラー)"
      e.note "  #{e.error}  = ERROR"
      e.note "  #{e.state(layout.steps_per_cycle_addr)}  = STEPS_PER_CYCLE"
      e.note "  #{e.opcode}  = CURRENT_OPCODE (デバッグ用)"
      e.note "  #{e.operand(:a)}  = operand a"
      e.note "  #{e.operand(:b)}  = operand b"
      e.note "  #{e.operand(:c)}  = operand c"
      e.note "  #{e.state(layout.reset_req_addr)} = RESET_REQ (1=リセット要求, vm_init で処理)"
      e.note "  #{e.scratch_lo} = 32ビット合成スクラッチ 下位ワード"
      e.note "  #{e.scratch_hi} = 32ビット合成スクラッチ 上位ワード"
      e.note "         #{layout.device_name} は無サフィックスだと16ビット符号なしのため、負値や"
      e.note "         65535 超の即値は一旦この2ワードに置いてから .L で読む"
      e.note "  #{e.state(layout.reg_base_addr)} = REG_BASE (レジスタ窓の先頭。呼び出しでずれる)"
      e.note "  #{e.state(layout.cur_bytecode_addr)} = 実行中の irep のバイトコード先頭"
      e.note "  #{e.state(layout.cur_pool_addr)} = 実行中の irep の定数プール先頭"
      e.note "  #{e.state(layout.cur_symbols_addr)} = 実行中の irep のシンボル表先頭"
      e.note "  #{e.state(layout.array_sp_addr)} = ARRAY_SP (次に渡す配列スロット。返さないので減らない)"
      e.note "  +#{layout.offset_of(layout.reg_file_base)}~ = レジスタスタック (値スロット #{SLOT_WORDS}ワード/レジスタ)"
      e.note "  +#{layout.offset_of(layout.frame_stack_base)}~ = 呼び出しスタック " \
             "(#{MemoryLayout::FRAME_WORDS}ワード/段)"
      e.note "  +#{layout.offset_of(layout.method_table_base)}~ = メソッド表 (1ワード/メソッド)"
      e.note "  +#{layout.offset_of(layout.general_global_base)}~ = 汎用グローバル変数 " \
             "(値スロット #{SLOT_WORDS}ワード/変数)"
      e.note "  +#{layout.offset_of(layout.array_pool_base)}~ = 配列プール " \
             "(#{layout.array_slot_words}ワード/スロット: 要素数 + 予備 + 要素#{layout.max_array_len}個)"
      e.note ""
      e.note "実行中に変わらないものは #{layout.fixed_device_name} " \
             "(#{layout.fixed_host_device} をバンク #{MemoryLayout::FIXED_BANK} に分けたもの) に置く。"
      e.note "スクリプトの先頭で FRSET(#{MemoryLayout::FIXED_BANK}) を実行済みのため、" \
             "#{layout.fixed_device_name} のアドレスで直接指せる。"
      e.note "インスタンス#{layout.instance_index}のブロックは " \
             "#{layout.fixed_device(layout.fixed_origin)}-" \
             "#{layout.fixed_device(layout.fixed_origin + layout.fixed_instance_size - 1)}:"
      e.note "  #{layout.fixed_device(layout.irep_table_base)}~ = IREPテーブル " \
             "(#{MemoryLayout::IREP_TABLE_STRIDE}ワード/irep)"
      e.note "  #{layout.fixed_device(layout.bytecode_base)}~ = バイトコード (1バイト/1ワード)"
      e.note "  #{layout.fixed_device(layout.pool_base)}~ = 定数プール (値スロット #{SLOT_WORDS}ワード/エントリ)"
      e.note "  #{layout.fixed_device(layout.device_table_base)}~ = シンボル表 " \
             "(#{DEVICE_TABLE_STRIDE}ワード/エントリ)"
      e.note ""
      e.note "バイトコード・定数プール・シンボル表は全 irep で 1 つの領域を分け合う。"
      e.note "irep ごとの位置は IREP テーブルにあり、切り替え時に VM 状態へ写す。"
      e.note "そのため上のアドレスは領域の先頭であって、実行中の位置ではない。"
      e.note "**インスタンスごとに位置が違うため、EM#{layout.offset_of(layout.irep_table_addr_addr)}:Z9 " \
             "から引く。**"
      e.note ""
      e.note "Z#{KvsEmitter::USED_Z.first}-Z#{KvsEmitter::USED_Z.last} を使用 " \
             "(Z11/Z12 は特別な用途があり使用不可、Z10 は未使用)"
      e.note "  Z はラダーと共有する資源のため、スクリプトの先頭で退避し末尾で復元する。"
      e.note "  faRuby の実行前後で Z の内容は変わらない。"
      e.note "  退避先 #{layout.device(layout.z_save_addr(KvsEmitter::USED_Z.first))}-" \
             "#{layout.device(layout.z_save_addr(KvsEmitter::USED_Z.last))} " \
             "(インスタンスループの外なので絶対アドレス)"
      e.note ""
      e.note "【重要】インデックス修飾と型サフィックスの順序"
      e.note "  正: EM0.L:Z1   デバイスに .L が付く → 32ビットアクセス"
      e.note "  誤: EM0:Z1.L   .L がインデックスレジスタ Z1 に結合してしまい、"
      e.note "                 エラーにならないまま16ビットアクセスになる"
      e.note "  インデックスの刻み幅は .L でも 1 ワード。下位ワードが先。"
    end

    def emit_fetch(e)
      e.note "=== FETCH OPCODE ==="
      e.line "Z1 = #{e.pc} + #{e.bytecode_offset}"
      e.line "#{e.opcode} = #{e.fixed_indexed_base}:Z1"
      e.line "#{e.pc} = #{e.pc} + 1"
      e.count_step
      e.blank
    end

    # 命令の振り分けを何組に分けるか
    #
    # **KV Studio は「対のない LABEL / CJ / GOTO」を 200 までしか許しません。**
    # `IF` / `ELSE IF` はラダーの条件ジャンプになり、連なりの各枝は連なりの
    # 終わりへ飛ぶので `END IF` が出るまで対になりません。**1 本の連なりに
    # 枝を並べるほど溜まります。**
    #
    # 番号の範囲で組に分け、まず組を選んでから中を見ます。溜まりは
    # 「組の数 + 組の中の枝の数」で済み、1 本に並べたときの命令数より
    # ずっと小さくなります。
    #
    # 速度にも効きます。今までは後ろの命令ほど手前の枝を全部通っていましたが、
    # 組を選ぶ比較 1-3 回で飛び越えられます。**手前にある比較の数だけが効く**
    # というこれまでの測定と合います。
    DISPATCH_GROUPS = 4

    def emit_dispatch(e)
      groups = @opcodes.each_slice((@opcodes.size.to_f / DISPATCH_GROUPS).ceil).to_a

      e.note "=== DECODE & EXECUTE ==="
      e.note "番号の範囲で #{groups.size} 組に分ける。1 本の連なりに #{@opcodes.size} 本"
      e.note "並べると、ラダーの「対のない LABEL / CJ / GOTO」が 200 を超える"
      e.blank

      groups.each_with_index do |group, i|
        last = i == groups.size - 1
        if last
          e.line "ELSE"
        else
          e.line(i.zero? ? "IF #{opcode_var} <= #{group.last.code} THEN" \
                         : "ELSE IF #{opcode_var} <= #{group.last.code} THEN")
        end
        e.indent
        e.note format("0x%02X - 0x%02X", group.first.code, group.last.code)
        emit_opcode_chain(e, group)
        e.dedent
      end
      e.line "END IF"
      e.blank
    end

    # 組の中の連なり。当たらなければ未知のオペコード
    def emit_opcode_chain(e, group)
      group.each_with_index do |op, i|
        e.line(i.zero? ? "IF #{opcode_var} = #{op.code} THEN" : "ELSE IF #{opcode_var} = #{op.code} THEN")
        e.indent
        e.begin_instruction
        e.note op.header_comment
        e.fetch_operands(op.operand_sizes)
        op.body&.call(e)
        e.dedent
        e.blank
      end

      e.line "ELSE"
      e.indent
      e.note "未知のオペコード: エラー"
      e.line "#{e.status} = #{VM_ERROR}"
      e.line "#{e.error} = #{e.opcode}"
      e.line "BREAK"
      e.dedent
      e.blank
      e.line "END IF"
    end

    def emit_range_check(e)
      e.note "バイトコード範囲チェック"
      e.if_("#{e.pc} >= #{e.state(layout.bytecode_len_addr)}") do
        e.line "#{e.status} = #{VM_FINISHED}"
        e.line "BREAK"
      end
      e.blank
    end
  end
end

if __FILE__ == $0
  puts FaRuby::KvsGenerator.new.source
end
