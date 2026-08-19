# frozen_string_literal: true

# シミュレータ用バックエンド
#
# tools/opcode_table.rb の命令定義を「実際に実行する」側の解釈です。
# KvsEmitter が同じ定義から KV スクリプトの文字列を組み立てるのに対し、
# SimVm は EM メモリ上で値を読み書きします。
#
# 両者が同じ定義を使うため、片方にだけ命令があるという食い違いが起きません。

require_relative "../tools/memory_map"

module MrubycOnPlc
  class SimVm
    include MemoryMap

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

    COMPARISON = {
      eq: ->(a, b) { a == b },  ne: ->(a, b) { a != b },
      lt: ->(a, b) { a < b },   le: ->(a, b) { a <= b },
      gt: ->(a, b) { a > b },   ge: ->(a, b) { a >= b },
    }.freeze

    def initialize(em, devices)
      @em = em
      @devices = devices
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
    def pool(name)     = @em.read_s32(MemoryMap.pool_addr(operand(name)))

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

    def set_reg(name, value)
      write_reg(operand(name), value)
    end

    def set_reg_bool(name, op, lhs, rhs)
      write_reg(operand(name), cmp(op, lhs, rhs) ? 1 : 0)
    end

    def set_reg_div(name, lhs, rhs, error_code)
      return vm_error(error_code) if rhs.zero?

      write_reg(operand(name), binop(:div, lhs, rhs))
    end

    def load_global_into_reg(dest, sym_operand)
      type, addr, access = device_entry(operand(sym_operand))
      dev = device_memory(type)
      return vm_error(0x15) unless dev

      value = if bit_device?(type)
                dev.read_u16(addr) != 0 ? 1 : 0
              else
                read_word_device(dev, addr, access)
              end
      write_reg(operand(dest), value)
    end

    def store_reg_into_global(sym_operand, src)
      type, addr, access = device_entry(operand(sym_operand))
      dev = device_memory(type)
      return vm_error(0x16) unless dev

      value = read_reg(operand(src))
      if bit_device?(type)
        dev.write_u16(addr, value != 0 ? 1 : 0)
      else
        write_word_device(dev, addr, access, value)
      end
    end

    # 16ビットオペランドを符号付きとして解釈する
    def normalize_signed16(name)
      @operands[name] = sign_extend(@operands.fetch(name) & 0xFFFF, 16)
    end

    def jump_relative(name)
      @em.write_u16(PC_ADDR, pc + operand(name))
    end

    def vm_finish
      @em.write_u16(STATUS_ADDR, VM_FINISHED)
    end

    def vm_error(code)
      @em.write_u16(STATUS_ADDR, VM_ERROR)
      @em.write_u16(ERROR_ADDR, code)
    end

    # 条件が真のときだけブロックを実行する
    # (KvsEmitter は常にブロックを実行してコードを出力する点が異なる)
    def if_(cond)
      yield if cond
    end

    # 生成コード向けのコメント。実行時は何もしない
    def note(_text) = nil

    # --- メモリアクセス ---

    def pc = @em.read_u16(PC_ADDR)

    def read_reg(index)  = @em.read_s32(MemoryMap.reg_addr(index))
    def write_reg(index, value) = @em.write_s32(MemoryMap.reg_addr(index), value)

    # バイトコードから1バイト読み、PC を進める
    def fetch_byte
      current = pc
      value = @em.read_u16(MemoryMap.bytecode_addr(current))
      @em.write_u16(PC_ADDR, current + 1)
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
      table_addr = DEVICE_TABLE_BASE + idx * DEVICE_TABLE_STRIDE
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
