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

    # faRuby が書き換える Z レジスタ
    #
    # PLC の Z はラダーと共有する資源なので、スクリプトの先頭で退避し
    # 末尾で復元する。ここに挙げたものだけを使うことを
    # test_kvs_generator.rb が検証する。
    #
    # Z11 / Z12 は特別な用途があり使用できない (実機で確認済み)。
    # 使えるのは Z1-Z10 で、faRuby が Z1-Z9 を使うため
    # ラダー側に残るのは Z10 の1本。
    USED_Z = (1..9).to_a.freeze

    # ワードデバイス (アクセス幅の選択が必要)
    WORD_DEVICES = [[DEVICE_TYPE_EM, "EM"], [DEVICE_TYPE_DM, "DM"], [DEVICE_TYPE_ZF, "ZF"]].freeze

    # ビットデバイス。set_res が true のものは代入ではなく SET/RES を使う
    BIT_DEVICES = [
      [DEVICE_TYPE_R,  "R",  false], [DEVICE_TYPE_MR, "MR", false],
      [DEVICE_TYPE_B,  "B",  false], [DEVICE_TYPE_L,  "L",  false],
      [DEVICE_TYPE_T,  "T",  true],  [DEVICE_TYPE_C,  "C",  true],
    ].freeze

    # アクセス幅の分岐順。最後 (.S) が ELSE になる
    ACCESS_BRANCHES = [[ACCESS_L, "L"], [ACCESS_U, "U"], [ACCESS_D, "D"], [ACCESS_F, "F"]].freeze
    ACCESS_DEFAULT_SUFFIX = "S"

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

    def reg_slot(name)      = slot_ref([:reg, name], "#{operand(name)} * #{SLOT_WORDS}", layout.reg_file_base)
    def reg_next_slot(name) = slot_ref([:reg_next, name], "(#{operand(name)} + 1) * #{SLOT_WORDS}", layout.reg_file_base)
    def pool_slot(name)     = slot_ref([:pool, name], "#{operand(name)} * #{SLOT_WORDS}", layout.pool_base)

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
                     layout.reg_file_base, z: Z_SECONDARY)
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
      lhs = reg_slot(name)
      rhs = reg_next_slot(name)

      note "数値は型が違っても値で比べる (Ruby では 1 == 1.0 は真)"
      note "数値以外は型と値の両方が一致したときだけ真 (nil == false は偽)"
      note "結果を R[a] に書くと比較元が壊れるため、先に判定してから代入する"
      line "#{scratch_lo} = 0"

      if_else_block(numeric?(lhs.tag)) do
        if_else_block(numeric?(rhs.tag)) do
          numeric_dispatch(lhs, rhs, rhs_tag: rhs.tag) do |_kind, l, r|
            if_(cmp(:eq, l, r)) { line "#{scratch_lo} = 1" }
          end
        end
        note "数値と非数値は等しくない"
        end_block
      end
      if_(cmp(:eq, lhs.tag, rhs.tag)) do
        if_(cmp(:eq, lhs.value, rhs.value)) { line "#{scratch_lo} = 1" }
      end
      end_block

      if_else_block("#{scratch_lo} = 1") { assign_bool(lhs, true) }
      assign_bool(lhs, false)
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

    def load_global_into_reg(dest, sym_operand)
      device_table_lookup(sym_operand)
      note "レジスタアドレス"
      device_dispatch(:read, slot: global_reg_slot(dest), error_code: 0x15)
    end

    def store_reg_into_global(sym_operand, src)
      device_table_lookup(sym_operand)
      note "レジスタアドレス"
      slot = global_reg_slot(src)
      prepare_write_scratches(slot)
      device_dispatch(:write, slot: slot, error_code: 0x16)
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
        bytes == 1 ? fetch_byte(target) : fetch_u16(target)
      end
    end

    # --- デバイスアクセス ---

    # デバイスマッピングテーブルから type / address / access_type を読む
    def device_table_lookup(name)
      note "デバイスマッピングテーブル参照 (#{DEVICE_TABLE_STRIDE}ワード/エントリ)"
      line "Z3 = #{operand(name)} * #{DEVICE_TABLE_STRIDE} + #{block_offset(layout.device_table_base)}"
      line "Z4 = Z3 + 1"
      line "Z5 = #{indexed_base}:Z3"
      line "Z6 = #{indexed_base}:Z4"
      line "Z7 = Z3 + 2"
      line "Z8 = #{indexed_base}:Z7"
    end

    # デバイス種別 × アクセス幅の分岐を生成する
    def device_dispatch(mode, slot:, error_code:)
      note "デバイスタイプ別#{mode == :read ? '読み取り' : '書き込み'}"
      note "ワードデバイス (EM, DM, ZF): Z8 (access_type) で幅を選ぶ"
      ACCESS_BRANCHES.each { |value, sfx| note "  #{value}=.#{sfx}(#{ACCESS_NAMES.fetch(value)})" }
      note "  それ以外=.#{ACCESS_DEFAULT_SUFFIX}(#{ACCESS_NAMES.fetch(ACCESS_S)}/既定)"
      if mode == :read
        note "ビットデバイス (R, MR, B, L, T, C): ON→true, OFF→false"
        note "  整数の 1/0 ではなく真偽値。0 は Ruby では真なので、"
        note "  整数にすると if $MR10 が常に成立してしまう"
      else
        note "ビットデバイス (R, MR, B, L, T, C): 非0→ON, 0→OFF"
        note "  true=1 / false=nil=0 なので値だけで判定できる"
      end

      first = true
      WORD_DEVICES.each do |type, name|
        chain_head(first, "Z5 = #{type}")
        first = false
        indent
        word_device_body(mode, name, slot)
        dedent
      end

      BIT_DEVICES.each do |type, name, set_res|
        chain_head(first, "Z5 = #{type}")
        first = false
        indent
        bit_device_body(mode, name, slot, set_res)
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
    def numeric?(tag) = "#{tag} >= #{TT_INTEGER}"

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
      line "#{dest.word(0)} = 0"
      if_else_block("#{lhs} > 0") { line "#{dest.word(1)} = #{FLOAT_POS_INF_HI}   ' +Infinity" }
      if_else_block("#{lhs} < 0") { line "#{dest.word(1)} = #{FLOAT_NEG_INF_HI}   ' -Infinity" }
      line "#{dest.word(1)} = #{FLOAT_NAN_HI}   ' 0.0 / 0.0 は NaN"
      end_block
      end_block
      end_block
      line "#{dest.tag} = #{TT_FLOAT}"
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
      slot_ref([:reg, name], "#{operand(name)} * #{SLOT_WORDS}", layout.reg_file_base, z: Z_SECONDARY)
    end

    # 値スロットの先頭アドレスを Z に設定し、タグと値の参照を返す
    # 同じスロットを同一命令内で複数回参照しても Z 設定は1度だけ出力する
    #
    # 型サフィックスはデバイス側に付ける (EM1.L:Z1)。
    # EM1:Z1.L と書くと .L がインデックスレジスタに結合し、
    # エラーにならないまま16ビットアクセスに退化する。
    def slot_ref(key, index_expr, base, z: nil)
      return @slot_cache[key] if @slot_cache.key?(key)

      z ||= key == [:reg, :a] ? Z_PRIMARY : Z_SECONDARY
      line "Z#{z} = #{index_expr} + #{block_offset(base)}"
      @slot_cache[key] = Slot.new("#{layout.device_name}#{SLOT_TYPE_OFFSET}:Z#{z}",
                                  z, layout.device_name)
    end

    # バイトコードの現在位置を Z1 経由で読み、PC を1つ進める
    def read_bytecode_into(dest)
      line "Z1 = #{pc} + #{block_offset(layout.bytecode_base)}"
      line "#{dest} = #{indexed_base}:Z1"
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

    def chain_head(first, cond)
      line(first ? "IF #{cond} THEN" : "ELSE IF #{cond} THEN")
    end

    def word_device_body(mode, name, slot)
      first = true
      ACCESS_BRANCHES.each do |value, suffix|
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

    # 書き込み用に、レジスタの値を整数と実数の両方の形で用意する
    #
    # 実数レジスタを .S へ書くときは数値変換 (0方向へ切り捨て) が要り、
    # 整数レジスタを .F へ書くときは逆の変換が要る。ここで1度だけ済ませて
    # おけば、アクセス幅ごとの分岐でレジスタの型を見なくてよくなる。
    def prepare_write_scratches(slot)
      note "レジスタの値を整数・実数の両方の形で用意する"
      note "アクセス幅ごとの分岐で型を見なくて済むようにするため"
      if_else_block("#{slot.tag} = #{TT_FLOAT}") do
        line "#{scratch32} = #{slot.float}      ' 実数→整数 (0方向へ切り捨て)"
        line "#{scratch_float} = #{slot.float}"
      end
      line "#{scratch32} = #{slot.value}"
      line "#{scratch_float} = #{slot.value}      ' 整数→実数"
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
      e.restore_z_registers
      "#{e.lines.join("\n")}\n"
    end

    def build_source
      e = KvsEmitter.new(layout: layout)
      emit_header(e)
      e.blank
      e.save_z_registers
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
      e.note "  +#{layout.offset_of(layout.reg_file_base)}~ = レジスタファイル (値スロット #{SLOT_WORDS}ワード/レジスタ)"
      e.note "  +#{layout.offset_of(layout.bytecode_base)}~ = バイトコード (1バイト/1ワード)"
      e.note "  +#{layout.offset_of(layout.pool_base)}~ = 定数プール (値スロット #{SLOT_WORDS}ワード/エントリ)"
      e.note "  +#{layout.offset_of(layout.device_table_base)}~ = デバイスマッピングテーブル " \
             "(#{DEVICE_TABLE_STRIDE}ワード/エントリ)"
      e.note ""
      e.note "Z#{KvsEmitter::USED_Z.first}-Z#{KvsEmitter::USED_Z.last} を使用 " \
             "(Z11/Z12 は特別な用途があり使用不可、Z10 はラダー用に残す)"
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
      e.line "Z1 = #{e.pc} + #{e.block_offset(layout.bytecode_base)}"
      e.line "#{e.opcode} = #{e.indexed_base}:Z1"
      e.line "#{e.pc} = #{e.pc} + 1"
      e.blank
    end

    def emit_dispatch(e)
      e.note "=== DECODE & EXECUTE ==="
      e.blank

      @opcodes.each_with_index do |op, i|
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
      e.blank
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
