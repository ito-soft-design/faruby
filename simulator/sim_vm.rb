# frozen_string_literal: true

# シミュレータ用バックエンド
#
# tools/opcode_table.rb の命令定義を「実際に実行する」側の解釈です。
# KvsEmitter が同じ定義から KV スクリプトの文字列を組み立てるのに対し、
# SimVm は EM メモリ上で値を読み書きします。
#
# 両者が同じ定義を使うため、片方にだけ命令があるという食い違いが起きません。

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"

module FaRuby
  class SimVm
    include VmConstants

    # ビットデバイスタイプ (R, MR, B, L, T, C)
    # CR はインデックス扱い不可のため非対応
    BIT_DEVICE_TYPES = [DEVICE_TYPE_R, DEVICE_TYPE_MR, DEVICE_TYPE_B,
                        DEVICE_TYPE_L, DEVICE_TYPE_T, DEVICE_TYPE_C].freeze

    ARITHMETIC = {
      add: ->(a, b) { a + b },
      sub: ->(a, b) { a - b },
      mul: ->(a, b) { a * b },
      div: ->(a, b) { a / b },
    }.freeze

    # 実数は単精度 (IEEE754 32ビット)
    #
    # Ruby の Float は倍精度なので、そのままでは実機と結果がずれます。
    # 演算のたびに単精度へ丸めて PLC に合わせます。
    def self.to_single(value) = [value.to_f].pack("e").unpack1("e")

    def self.float_bits(value) = [value.to_f].pack("e").unpack1("V")
    def self.bits_to_float(bits) = [bits & 0xFFFF_FFFF].pack("V").unpack1("e")

    COMPARISON = {
      eq: ->(a, b) { a == b },  ne: ->(a, b) { a != b },
      lt: ->(a, b) { a < b },   le: ->(a, b) { a <= b },
      gt: ->(a, b) { a > b },   ge: ->(a, b) { a >= b },
    }.freeze

    attr_reader :layout

    # fixed は固定領域 (実機では FM = バンク 3 の ZF) のメモリ。
    # 省略すると em と同じものを使う (領域を分ける前の書き方との互換)。
    def initialize(em, devices, layout: MemoryLayout.default, fixed: nil)
      @em = em
      @fixed = fixed || em
      @devices = devices
      @layout = layout
      @operands = {}
    end

    # 命令の実行開始時にオペランドをセットする
    def begin_instruction(operands)
      @operands = operands
    end

    # --- 値 ---

    def operand(name) = @operands.fetch(name)
    def const(n)      = n

    def reg(name)      = read_reg(operand(name))
    def reg_next(name) = read_reg(operand(name) + 1)
    def pool(name)     = @fixed.read_s32(pool_value_addr(operand(name)))

    def reg_tag(name)      = read_reg_tag(operand(name))
    def reg_next_tag(name) = read_reg_tag(operand(name) + 1)

    def binop(op, lhs, rhs) = ARITHMETIC.fetch(op).call(lhs, rhs)
    def cmp(op, lhs, rhs)   = COMPARISON.fetch(op).call(lhs, rhs)

    def sign_extend(value, bits)
      threshold = 1 << (bits - 1)
      value >= threshold ? value - (1 << bits) : value
    end

    def compose32(hi, lo)
      value = ((hi & 0xFFFF) << 16) | (lo & 0xFFFF)
      value >= 0x8000_0000 ? value - 0x1_0000_0000 : value
    end

    def negate(value) = -value

    # --- 動作 ---

    def set_reg_int(name, value)
      write_slot(operand(name), TT_INTEGER, value)
    end

    # --- 数値演算 (整数・実数の振り分け) ---
    #
    # 生成コード側はタグを見て .F と .L のどちらの書き方を出すかを選ぶ。
    # ここでは Ruby の値として素直に計算し、実数なら単精度へ丸める。

    def set_reg_arith(name, op, immediate: nil)
      index = operand(name)
      lhs = numeric_value(index)
      rhs = immediate ? operand(immediate) : numeric_value(index + 1)

      if float_operand?(index) || (immediate.nil? && float_operand?(index + 1))
        write_float(index, binop(op, lhs.to_f, rhs.to_f))
      else
        write_slot(index, TT_INTEGER, binop(op, lhs, rhs))
      end
    end

    def set_reg_cmp(name, op)
      index = operand(name)
      write_bool(index, cmp(op, numeric_value(index), numeric_value(index + 1)))
    end

    def set_reg_special(name, tag)
      write_slot(operand(name), tag, TT_CANONICAL_VALUE.fetch(tag))
    end

    def move_reg(dest_name, src_name)
      src = operand(src_name)
      write_slot(operand(dest_name), read_reg_tag(src), read_reg(src))
    end

    def load_pool(dest_name, pool_name)
      index = operand(pool_name)
      write_slot(operand(dest_name),
                 @fixed.read_u16(pool_type_addr(index)),
                 @fixed.read_s32(pool_value_addr(index)))
    end

    def set_reg_bool(name, op, lhs, rhs)
      write_bool(operand(name), cmp(op, lhs, rhs))
    end

    # 数値は型が違っても値で比べ (1 == 1.0 は真)、
    # 数値以外は型と値の両方が一致したときだけ真 (nil == false は偽)
    def set_reg_eq(name)
      index = operand(name)
      same =
        if numeric_tag?(read_reg_tag(index)) && numeric_tag?(read_reg_tag(index + 1))
          numeric_value(index) == numeric_value(index + 1)
        else
          read_reg_tag(index) == read_reg_tag(index + 1) &&
            read_reg(index) == read_reg(index + 1)
        end
      write_bool(index, same)
    end

    # R[a] = R[a] / R[a+1]
    #
    # 整数どうしは Ruby の / がそのまま切り下げなので補正は要らない
    # (KV スクリプトの / は 0 方向へ切り捨てるため生成コード側で補正している)。
    # 実数が絡む 0 除算は Ruby と同じく Infinity / NaN になる。
    def set_reg_div(name, error_code)
      index = operand(name)
      lhs = numeric_value(index)
      rhs = numeric_value(index + 1)

      if float_operand?(index) || float_operand?(index + 1)
        return write_float(index, float_div_result(lhs.to_f, rhs.to_f))
      end

      return vm_error(error_code) if rhs.zero?

      write_slot(index, TT_INTEGER, binop(:div, lhs, rhs))
    end

    def load_global_into_reg(dest, sym_operand)
      type, addr, access, kind = device_entry(operand(sym_operand))
      dev = device_memory(type)
      return vm_error(0x15) unless dev
      return write_device_ref(operand(dest), type, addr, access) if kind == SYMBOL_KIND_FAMILY

      read_device_into(dev, addr, access, operand(dest), bit_device: bit_device?(type))
    end

    # --- メソッドの定義と呼び出し ---

    # R[a] = 子 irep b への参照 (OP_METHOD)
    #
    # irep は幅優先に並べてあり同じ親の子が連続するため、実行中の irep の
    # 最初の子の番号に b を足せば通し番号になる。
    def load_child_irep(name, child_name, error_code)
      index = irep_word(cur_irep, MemoryLayout::IREP_FIRST_CHILD) + operand(child_name)
      return vm_error(error_code) if index >= @em.read_u16(layout.num_ireps_addr)

      write_slot(operand(name), TT_PROC, index)
    end

    # メソッド表に symbols[b] = R[a+1] を登録する (OP_DEF)
    def define_method(name, sym_name, error_code)
      _code, method_id, _argc, kind = device_entry(operand(sym_name))
      return vm_error(error_code) unless kind == SYMBOL_KIND_METHOD
      return vm_error(error_code) if method_id == METHOD_ID_NONE

      body = operand(name) + 1
      return vm_error(error_code) unless read_reg_tag(body) == TT_PROC

      @em.write_u16(layout.method_table_addr(method_id), read_reg(body))
      write_slot(operand(name), TT_SYMBOL, operand(sym_name))
    end

    # R[a] = self.メソッド(R[a+1]..) (OP_SSEND)
    def send_self_method(name, sym_name, argc_name, unknown_code, type_code,
                         zero_code, depth_code)
      index = operand(name)
      write_slot(index, read_reg_tag(0), read_reg(0))   # regs[a] = self

      code, method_id, argc, kind = device_entry(operand(sym_name))
      return vm_error(unknown_code) unless kind == SYMBOL_KIND_METHOD
      return dispatch_builtin(code, index, operand(argc_name), argc,
                              unknown_code, type_code, zero_code) unless code == METHOD_NONE

      call_user_method(index, method_id, operand(argc_name), unknown_code, depth_code)
    end

    # ユーザー定義メソッドへ移る
    def call_user_method(index, method_id, argc, unknown_code, depth_code)
      return vm_error(unknown_code) if method_id == METHOD_ID_NONE

      irep = @em.read_u16(layout.method_table_addr(method_id))
      return vm_error(unknown_code) if irep == METHOD_UNDEFINED
      return vm_error(depth_code) if frame_sp >= layout.max_frames

      push_frame
      # 呼ばれた側の R[0] は呼んだ側の R[a] と同じ場所になる
      @em.write_u16(layout.reg_base_addr,
                    @em.read_u16(layout.reg_base_addr) + index * SLOT_WORDS)
      @em.write_u16(layout.call_argc_addr, argc)
      switch_to_irep(irep)
      return vm_error(depth_code) unless register_window_fits?

      @em.write_u16(layout.pc_addr, 0)
    end

    # メソッド本体の入口 (OP_ENTER)
    #
    # 生成コード側は aspec を上位バイトと下位2バイトに分けて持つ (16ビットに
    # 収まらないため)。こちらは 24 ビットのまま扱うが、判定は同じ。
    def enter_method(name, error_code)
      aspec = operand(name)
      required = aspec >> ASPEC_REQ_SHIFT
      return vm_error(error_code) unless aspec == required << ASPEC_REQ_SHIFT
      return vm_error(error_code) unless @em.read_u16(layout.call_argc_addr) == required

      # 引数の後ろのレジスタを空にする (未代入のローカル変数は偽になる)
      ((required + 1)...@em.read_u16(layout.nregs_addr)).each do |i|
        SLOT_WORDS.times { |w| @em.write_u16(reg_base + i * SLOT_WORDS + w, 0) }
      end
    end

    # 呼び出し元へ戻る (OP_RETURN)
    def return_from_method(name)
      return vm_finish if frame_sp.zero?

      # R[a] を R[0] へ写す。R[0] は呼んだ側の R[a] と同じ場所
      index = operand(name)
      write_slot(0, read_reg_tag(index), read_reg(index))

      @em.write_u16(layout.frame_sp_addr, frame_sp - 1)
      addr = layout.frame_addr(frame_sp)
      @em.write_u16(layout.pc_addr, @em.read_u16(addr + MemoryLayout::FRAME_RETURN_PC))
      @em.write_u16(layout.reg_base_addr, @em.read_u16(addr + MemoryLayout::FRAME_RETURN_BASE))
      switch_to_irep(@em.read_u16(addr + MemoryLayout::FRAME_RETURN_IREP))
    end

    # --- 組み込みメソッド ---
    #
    # 呼び出しフレームは作らない。引数は R[a+1] から連続して並び、
    # 結果は R[a] に返る。生成コードと同じ規則で計算する。
    def send_method(name, sym_name, argc_name, unknown_code, type_code, zero_code)
      code, _id, argc, kind = device_entry(operand(sym_name))
      return vm_error(unknown_code) unless kind == SYMBOL_KIND_METHOD

      dispatch_builtin(code, operand(name), operand(argc_name), argc,
                       unknown_code, type_code, zero_code)
    end

    def dispatch_builtin(code, index, given_argc, argc, unknown_code, type_code, zero_code)
      return vm_error(unknown_code) unless given_argc == argc
      return vm_error(type_code) if code >= METHOD_NUMERIC_MIN && !numeric_tag?(read_reg_tag(index))
      return vm_error(unknown_code) unless METHOD_NAMES.key?(code)

      apply_method(code, index, type_code, zero_code)
    end

    # デバイスの値をレジスタへ読む (生成コードと同じ規則)
    #
    # 幅サフィックスの有無で意味が変わる。無しなら個別ビット、
    # 有りなら整数 (MR 等はビット列、T/C は現在値)。
    def read_device_into(dev, addr, access, index, bit_device: false)
      if access == ACCESS_BIT
        write_bool(index, dev.read_u16(addr) != 0)
      elsif bit_device
        write_slot(index, TT_INTEGER, read_bit_field(dev, addr, access))
      elsif access == ACCESS_F
        write_float(index, SimVm.bits_to_float(dev.read_u32(addr)))
      else
        write_slot(index, TT_INTEGER, read_word_device(dev, addr, access))
      end
    end

    # --- ビットデバイスの幅アクセス ---
    #
    # 実機はそのビットから連続したビット列を整数として扱います (1ビット刻み、
    # チャンネル境界に揃っていなくてよい)。シミュレータはビットを 1 ワードに
    # 1 個ずつ持っているため、読み書きのたびに組み立て直します。
    #
    # T / C は実機では現在値を返しますが、シミュレータにタイマは無いため
    # 再現できません。ここではビット列として扱います。

    def access_bits(access) = ACCESS_WORDS.fetch(access, 1) * 16

    def read_bit_field(dev, addr, access)
      bits = access_bits(access)
      value = (0...bits).sum { |i| dev.read_u16(addr + i).zero? ? 0 : (1 << i) }
      signed = [ACCESS_S, ACCESS_L].include?(access)
      signed && value >= (1 << (bits - 1)) ? value - (1 << bits) : value
    end

    def write_bit_field(dev, addr, access, value)
      access_bits(access).times { |i| dev.write_u16(addr + i, (value >> i) & 1) }
    end

    def store_reg_into_global(sym_operand, src)
      type, addr, access, kind = device_entry(operand(sym_operand))
      dev = device_memory(type)
      return vm_error(0x16) unless dev
      return vm_error(0x16) if kind == SYMBOL_KIND_FAMILY # $DM = 1 は意味を持たない

      write_device_value(dev, type, addr, access, operand(src))
    end

    # --- 添字によるデバイスアクセス ---
    #
    # $DM[100 + i] のように実行時にアドレスを決める。

    # R[a] = R[a][R[a+1]]
    def load_device_index(name, error_code)
      index = operand(name)
      ref = device_ref(index)
      return vm_error(error_code) unless ref

      addr = device_index_address(ref, read_reg(index + 1))
      return vm_error(error_code) unless addr

      dev = device_memory(ref[:type])
      return vm_error(error_code) unless dev

      read_device_into(dev, addr, ref[:access], index, bit_device: bit_device?(ref[:type]))
    end

    # R[a][R[a+1]] = R[a+2]
    def store_device_index(name, error_code)
      index = operand(name)
      ref = device_ref(index)
      return vm_error(error_code) unless ref

      addr = device_index_address(ref, read_reg(index + 1))
      return vm_error(error_code) unless addr

      dev = device_memory(ref[:type])
      return vm_error(error_code) unless dev

      write_device_value(dev, ref[:type], addr, ref[:access], index + 2)
    end

    # 16ビットオペランドを符号付きとして解釈する
    def normalize_signed16(name)
      @operands[name] = sign_extend(@operands.fetch(name) & 0xFFFF, 16)
    end

    def jump_relative(name)
      @em.write_u16(layout.pc_addr, pc + operand(name))
    end

    def vm_finish
      @em.write_u16(layout.status_addr, VM_FINISHED)
    end

    def vm_error(code)
      @em.write_u16(layout.status_addr, VM_ERROR)
      @em.write_u16(layout.error_addr, code)
    end

    # 条件が真のときだけブロックを実行する
    # (KvsEmitter は常にブロックを実行してコードを出力する点が異なる)
    def if_(cond)
      yield if cond
    end

    # --- 真偽判定 ---
    #
    # Ruby で偽なのは nil と false だけ。0 も真。

    def if_truthy(name) = (yield if reg_tag(name) > TT_FALSY_MAX)
    def if_falsy(name)  = (yield if reg_tag(name) <= TT_FALSY_MAX)
    def if_nil(name)    = (yield if reg_tag(name) == TT_NIL)

    # 生成コード向けのコメント。実行時は何もしない
    def note(_text) = nil

    # --- メモリアクセス ---

    def pc = @em.read_u16(layout.pc_addr)

    # 実行中の irep とレジスタ窓の位置
    #
    # irep が複数になり、呼び出しごとにレジスタ窓もずれるため、これらの位置は
    # 固定ではありません。生成コードと同じく VM 状態から引きます。値は
    # ブロック先頭からのオフセットなので、絶対アドレスにするため origin を足します。
    # レジスタ窓 (可変領域) はブロック先頭からのオフセット。バイトコード・
    # 定数プール・シンボル表は固定領域 (FM) にあり、絶対アドレスがそのまま入る
    def reg_base      = layout.origin + @em.read_u16(layout.reg_base_addr)
    def bytecode_base = @em.read_u16(layout.cur_bytecode_addr)
    def pool_base     = @em.read_u16(layout.cur_pool_addr)
    def symbol_base   = @em.read_u16(layout.cur_symbols_addr)

    # 固定領域のメモリ。実機では FM (バンク 3 の ZF)
    def fixed = @fixed

    def cur_irep = @em.read_u16(layout.cur_irep_addr)
    def frame_sp = @em.read_u16(layout.frame_sp_addr)

    def irep_word(index, field) = @fixed.read_u16(layout.irep_table_addr(index) + field)

    # 戻り先 (PC・irep・レジスタ窓) を積む
    def push_frame
      addr = layout.frame_addr(frame_sp)
      @em.write_u16(addr + MemoryLayout::FRAME_RETURN_PC, pc)
      @em.write_u16(addr + MemoryLayout::FRAME_RETURN_IREP, cur_irep)
      @em.write_u16(addr + MemoryLayout::FRAME_RETURN_BASE, @em.read_u16(layout.reg_base_addr))
      @em.write_u16(layout.frame_sp_addr, frame_sp + 1)
    end

    # 実行中の irep を切り替え、位置を VM 状態へ写す
    def switch_to_irep(index)
      @em.write_u16(layout.cur_irep_addr, index)
      { MemoryLayout::IREP_BYTECODE     => layout.cur_bytecode_addr,
        MemoryLayout::IREP_BYTECODE_LEN => layout.bytecode_len_addr,
        MemoryLayout::IREP_POOL         => layout.cur_pool_addr,
        MemoryLayout::IREP_SYMBOLS      => layout.cur_symbols_addr,
        MemoryLayout::IREP_NREGS        => layout.nregs_addr }.each do |field, addr|
        @em.write_u16(addr, irep_word(index, field))
      end
    end

    # レジスタ窓が領域に収まるか
    def register_window_fits?
      @em.read_u16(layout.reg_base_addr) + @em.read_u16(layout.nregs_addr) * SLOT_WORDS <=
        layout.offset_of(layout.reg_slot_addr(layout.max_regs))
    end

    def reg_addr(index)      = reg_base + index * SLOT_WORDS + SLOT_VALUE_OFFSET
    def reg_type_addr(index) = reg_base + index * SLOT_WORDS + SLOT_TYPE_OFFSET
    def pool_value_addr(index) = pool_base + index * SLOT_WORDS + SLOT_VALUE_OFFSET
    def pool_type_addr(index)  = pool_base + index * SLOT_WORDS + SLOT_TYPE_OFFSET

    def read_reg(index)     = @em.read_s32(reg_addr(index))
    def read_reg_tag(index) = @em.read_u16(reg_type_addr(index))

    def write_reg(index, value) = @em.write_s32(reg_addr(index), value)

    # 値スロットに型タグと値をまとめて書く
    def write_slot(index, tag, value)
      @em.write_u16(reg_type_addr(index), tag)
      @em.write_s32(reg_addr(index), value)
    end

    def write_bool(index, value)
      tag = value ? TT_TRUE : TT_FALSE
      write_slot(index, tag, TT_CANONICAL_VALUE.fetch(tag))
    end

    # --- 実数 ---
    #
    # 値ワードには IEEE754 単精度のビット列を置く (PLC 側と同じ表現)。

    def numeric_tag?(tag) = tag >= TT_INTEGER
    def float_operand?(index) = read_reg_tag(index) == TT_FLOAT

    def read_float(index) = SimVm.bits_to_float(@em.read_u32(reg_addr(index)))

    def write_float(index, value)
      @em.write_u16(reg_type_addr(index), TT_FLOAT)
      @em.write_u32(reg_addr(index), SimVm.float_bits(value))
    end

    # レジスタを数値として読む (タグに応じて整数か実数)
    def numeric_value(index)
      float_operand?(index) ? read_float(index) : read_reg(index)
    end

    # Ruby と同じく 0 除算は Infinity / NaN になる
    #
    # 生成コード側は KV の / が軽度エラー CR2012 を出すため、
    # 除数が 0 のときは IEEE754 のビット列を直接書いている。
    def float_div_result(lhs, rhs)
      return lhs / rhs unless rhs.zero?
      return Float::NAN if lhs.zero?

      lhs.positive? ? Float::INFINITY : -Float::INFINITY
    end

    # 組み込みメソッドの本体
    #
    # 生成コードは実数を単精度で扱うため、実数の結果は write_float で丸める。
    def apply_method(code, index, type_code, zero_code)
      case code
      when METHOD_NE    then send_ne(index)
      when METHOD_NOT   then write_bool(index, read_reg_tag(index) <= TT_FALSY_MAX)
      when METHOD_MOD   then send_mod(index, type_code, zero_code)
      when METHOD_ABS   then send_numeric(index) { |v| v.abs }
      when METHOD_TO_I  then write_slot(index, TT_INTEGER, numeric_value(index).to_i)
      when METHOD_TO_F  then write_float(index, numeric_value(index).to_f)
      when METHOD_FLOOR then write_slot(index, TT_INTEGER, numeric_value(index).floor)
      when METHOD_ROUND then write_slot(index, TT_INTEGER, round_away_from_zero(numeric_value(index)))
      else raise ArgumentError, "組み込みメソッドの本体がありません (#{code})"
      end
    end

    # 型が違えば等しくない (set_reg_eq の否定)
    def send_ne(index)
      same =
        if numeric_tag?(read_reg_tag(index)) && numeric_tag?(read_reg_tag(index + 1))
          numeric_value(index) == numeric_value(index + 1)
        else
          read_reg_tag(index) == read_reg_tag(index + 1) &&
            read_reg(index) == read_reg(index + 1)
        end
      write_bool(index, !same)
    end

    # 整数どうしのみ。Ruby の % は商を切り下げた余りで、符号は除数に合う
    def send_mod(index, type_code, zero_code)
      return vm_error(type_code) unless read_reg_tag(index) == TT_INTEGER
      return vm_error(type_code) unless read_reg_tag(index + 1) == TT_INTEGER

      rhs = read_reg(index + 1)
      return vm_error(zero_code) if rhs.zero?

      write_slot(index, TT_INTEGER, read_reg(index) % rhs)
    end

    # 型を保ったまま値だけ変える (abs)
    def send_numeric(index)
      value = yield(numeric_value(index))
      float_operand?(index) ? write_float(index, value) : write_slot(index, TT_INTEGER, value)
    end

    # Ruby の Float#round は 0 から遠い方へ丸める (2.5→3, -2.5→-3)
    # Ruby の Integer#round はそのまま
    def round_away_from_zero(value)
      return value if value.is_a?(Integer)

      value.negative? ? (value - 0.5).to_i : (value + 0.5).to_i
    end

    # バイトコードから1バイト読み、PC を進める
    def fetch_byte
      current = pc
      value = @fixed.read_u16(bytecode_base + current)
      @em.write_u16(layout.pc_addr, current + 1)
      value & 0xFF
    end

    # 命令形式に従ってオペランドを読む
    def fetch_operands(sizes)
      names = %i[a b c]
      sizes.each_with_index.to_h do |bytes, i|
        [names[i], bytes == 1 ? fetch_byte : fetch_uint(bytes)]
      end
    end

    private

    # ビッグエンディアンで n バイト読む
    def fetch_uint(bytes)
      bytes.times.reduce(0) { |acc, _| (acc << 8) | fetch_byte }
    end

    def device_entry(idx)
      table_addr = symbol_base + idx * DEVICE_TABLE_STRIDE
      [@fixed.read_u16(table_addr), @fixed.read_u16(table_addr + 1),
       @fixed.read_u16(table_addr + 2),
       @fixed.read_u16(table_addr + DEVICE_TABLE_KIND_OFFSET)]
    end

    # --- デバイス参照 (TT_DEVICE) ---
    #
    # 値ワードに「ベースアドレス」と「種別 + 幅 * 16」を詰める。
    # 予備ワードを使うと OP_MOVE が4ワード目まで複製する必要が出るため。

    def write_device_ref(index, type, base, access)
      @em.write_u16(reg_type_addr(index), TT_DEVICE)
      @em.write_u16(reg_addr(index), base)
      @em.write_u16(reg_addr(index) + 1, type + access * DEVICE_REF_ACCESS_SCALE)
    end

    # レジスタがデバイス参照ならその内容、違えば nil
    def device_ref(index)
      return nil unless read_reg_tag(index) == TT_DEVICE

      packed = @em.read_u16(reg_addr(index) + 1)
      { base: @em.read_u16(reg_addr(index)),
        type: packed % DEVICE_REF_ACCESS_SCALE,
        access: packed / DEVICE_REF_ACCESS_SCALE }
    end

    # ベース + 添字。範囲外なら nil
    #
    # 範囲外を許すと、EM では 512 ワード周期で別の場所を読み書きしてしまう。
    def device_index_address(ref, offset)
      addr = ref[:base] + offset
      addr.between?(0, 65_535) ? addr : nil
    end

    # レジスタの値をデバイスへ書く (生成コードと同じ変換規則)
    def write_device_value(dev, type, addr, access, index)
      if access == ACCESS_BIT
        dev.write_u16(addr, numeric_value(index) != 0 ? 1 : 0)
      elsif bit_device?(type)
        write_bit_field(dev, addr, access, integer_form(index))
      elsif access == ACCESS_F
        dev.write_u32(addr, SimVm.float_bits(numeric_value(index)))
      else
        write_word_device(dev, addr, access, integer_form(index))
      end
    end

    # 実数レジスタは 0 方向へ切り捨てて整数にする (生成コードと同じ規則)
    def integer_form(index)
      float_operand?(index) ? read_float(index).truncate : read_reg(index)
    end

    def device_memory(type)
      @devices[type] if type >= 0 && type < @devices.size
    end

    def bit_device?(type) = BIT_DEVICE_TYPES.include?(type)

    def read_word_device(dev, addr, access)
      case access
      when ACCESS_U then dev.read_u16(addr)
      when ACCESS_L then dev.read_s32(addr)
      when ACCESS_D then dev.read_u32(addr)
      else               dev.read_s16(addr)  # ACCESS_S (既定)
      end
    end

    def write_word_device(dev, addr, access, value)
      case access
      when ACCESS_U then dev.write_u16(addr, value)
      when ACCESS_L then dev.write_s32(addr, value)
      when ACCESS_D then dev.write_u32(addr, value)
      else               dev.write_s16(addr, value)  # ACCESS_S (既定)
      end
    end
  end
end
