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

    def initialize(em, devices, layout: MemoryLayout.default)
      @em = em
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
    def pool(name)     = @em.read_s32(layout.pool_addr(operand(name)))

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
                 @em.read_u16(layout.pool_type_addr(index)),
                 @em.read_s32(layout.pool_addr(index)))
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
      type, addr, access = device_entry(operand(sym_operand))
      dev = device_memory(type)
      return vm_error(0x15) unless dev

      if bit_device?(type)
        write_bool(operand(dest), dev.read_u16(addr) != 0)
      elsif access == ACCESS_F
        write_float(operand(dest), SimVm.bits_to_float(dev.read_u32(addr)))
      else
        write_slot(operand(dest), TT_INTEGER, read_word_device(dev, addr, access))
      end
    end

    def store_reg_into_global(sym_operand, src)
      type, addr, access = device_entry(operand(sym_operand))
      dev = device_memory(type)
      return vm_error(0x16) unless dev

      # 実数レジスタを .S 等へ書くときは 0 方向へ切り捨て、
      # 整数レジスタを .F へ書くときは実数へ変換する (生成コードと同じ規則)
      index = operand(src)
      if bit_device?(type)
        dev.write_u16(addr, numeric_value(index) != 0 ? 1 : 0)
      elsif access == ACCESS_F
        dev.write_u32(addr, SimVm.float_bits(numeric_value(index)))
      else
        value = float_operand?(index) ? read_float(index).truncate : read_reg(index)
        write_word_device(dev, addr, access, value)
      end
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

    def read_reg(index)     = @em.read_s32(layout.reg_addr(index))
    def read_reg_tag(index) = @em.read_u16(layout.reg_type_addr(index))

    def write_reg(index, value) = @em.write_s32(layout.reg_addr(index), value)

    # 値スロットに型タグと値をまとめて書く
    def write_slot(index, tag, value)
      @em.write_u16(layout.reg_type_addr(index), tag)
      @em.write_s32(layout.reg_addr(index), value)
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

    def read_float(index) = SimVm.bits_to_float(@em.read_u32(layout.reg_addr(index)))

    def write_float(index, value)
      @em.write_u16(layout.reg_type_addr(index), TT_FLOAT)
      @em.write_u32(layout.reg_addr(index), SimVm.float_bits(value))
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

    # バイトコードから1バイト読み、PC を進める
    def fetch_byte
      current = pc
      value = @em.read_u16(layout.bytecode_addr(current))
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
      table_addr = layout.device_table_base + idx * DEVICE_TABLE_STRIDE
      [@em.read_u16(table_addr), @em.read_u16(table_addr + 1), @em.read_u16(table_addr + 2)]
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
