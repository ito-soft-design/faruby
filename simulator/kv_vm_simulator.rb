# frozen_string_literal: true

# KV スクリプト VM シミュレータ
# PLC 上の KV スクリプト VM と同一ロジックで動作する PC 側シミュレータです。
# テスト・検証に使用します。

require_relative "em_memory"
require_relative "../tools/memory_map"
require_relative "../tools/mrb_parser"
require_relative "../tools/disasm"
require_relative "../tools/plc_codegen"

module MrubycOnPlc
  class KvVmSimulator
    include MemoryMap

    attr_reader :em, :devices

    def initialize
      @em = EmMemory.new
      @devices = Array.new(10) { EmMemory.new }
      @devices[0] = @em  # EM はメインメモリを共用
      @irep = nil
    end

    # メモリイメージをロードして実行
    def load_and_run(image, max_steps: 10000)
      @em.load_image(image)
      run(max_steps: max_steps)
    end

    # IREP から直接ロードして実行
    def load_irep_and_run(irep, max_steps: 10000)
      @irep = irep
      codegen = PlcCodegen.new(irep, steps_per_cycle: max_steps)
      image = codegen.memory_image
      load_and_run(image, max_steps: max_steps)
    end

    # ビットデバイスタイプ (R, MR, B, L, T, C)
    # CR はインデックス扱い不可のため非対応
    BIT_DEVICE_TYPES = [DEVICE_TYPE_R, DEVICE_TYPE_MR, DEVICE_TYPE_B,
                        DEVICE_TYPE_L, DEVICE_TYPE_T, DEVICE_TYPE_C].freeze

    # グローバル変数の値をシンボル名で取得 (テスト用)
    def global_value(sym_name)
      return nil unless @irep
      idx = @irep.symbols.index(sym_name)
      return nil unless idx
      table_addr = DEVICE_TABLE_BASE + idx * DEVICE_TABLE_STRIDE
      device_type = @em.read_u16(table_addr)
      device_addr = @em.read_u16(table_addr + 1)
      dev = device_memory(device_type)
      return nil unless dev
      if bit_device?(device_type)
        dev.read_u16(device_addr)
      else
        dev.read_s32(device_addr)
      end
    end

    # VM 実行ループ (KV スクリプトの FOR ループに対応)
    def run(max_steps: 10000)
      steps = 0

      while status == VM_RUNNING && steps < max_steps
        execute_one_instruction
        steps += 1
      end

      steps
    end

    # VM レジスタ R[n] の値を読む
    def reg(n)
      @em.read_s32(MemoryMap.reg_addr(n))
    end

    # VM 状態を読む
    def status
      @em.read_u16(STATUS_ADDR)
    end

    # PC を読む
    def pc
      @em.read_u16(PC_ADDR)
    end

    # レジスタダンプ
    def dump_registers(count = nil)
      count ||= @em.read_u16(NREGS_ADDR)
      count = [count, MAX_REGS].min
      puts "=== VM Registers ==="
      nlocals = @em.read_u16(NLOCALS_ADDR)
      count.times do |i|
        val = reg(i)
        label = case i
                when 0 then "(self)"
                when 1...nlocals then "(local)"
                else "(temp)"
                end
        puts format("  R[%d] = %d  %s", i, val, label)
      end
    end

    # VM 状態ダンプ
    def dump_status
      puts "=== VM Status ==="
      status_names = { VM_STOPPED => "STOPPED", VM_RUNNING => "RUNNING",
                       VM_FINISHED => "FINISHED", VM_ERROR => "ERROR" }
      puts "  PC     = #{pc}"
      puts "  STATUS = #{status_names[status] || status}"
      puts "  ERROR  = #{@em.read_u16(ERROR_ADDR)}"
      puts "  OPCODE = #{@em.read_u16(CURRENT_OPCODE)}"
    end

    private

    # 1命令を実行 (KV スクリプト VM と同一ロジック)
    def execute_one_instruction
      # フェッチ
      opcode = fetch_byte
      @em.write_u16(CURRENT_OPCODE, opcode)

      case opcode
      when 0x00 # OP_NOP
        # 何もしない

      when 0x01 # OP_MOVE (BB)
        a = fetch_byte
        b = fetch_byte
        write_reg(a, read_reg(b))

      when 0x02 # OP_LOADL (BB)
        a = fetch_byte
        b = fetch_byte
        val = @em.read_s32(MemoryMap.pool_addr(b))
        write_reg(a, val)

      when 0x03 # OP_LOADI8 (BB)
        a = fetch_byte
        b = fetch_byte
        val = b >= 128 ? b - 256 : b
        write_reg(a, val)

      when 0x04 # OP_LOADINEG (BB)
        a = fetch_byte
        b = fetch_byte
        write_reg(a, -b)

      when 0x05 # OP_LOADI__1 (B)
        a = fetch_byte
        write_reg(a, -1)

      when 0x06..0x0D # OP_LOADI_0 ~ OP_LOADI_7 (B)
        a = fetch_byte
        val = opcode - 0x06
        write_reg(a, val)

      when 0x0E # OP_LOADI16 (BS)
        a = fetch_byte
        b = fetch_s16
        write_reg(a, b)

      when 0x0F # OP_LOADI32 (BSS)
        a = fetch_byte
        b = fetch_u16
        c = fetch_u16
        val = (b << 16) | c
        val -= 0x1_0000_0000 if val >= 0x8000_0000
        write_reg(a, val)

      when 0x12 # OP_LOADSELF (B)
        a = fetch_byte
        write_reg(a, 0)  # トップレベルでは self = 0

      when 0x11 # OP_LOADNIL (B)
        a = fetch_byte
        write_reg(a, 0)  # nil = 0

      when 0x13 # OP_LOADTRUE (B)
        a = fetch_byte
        write_reg(a, 1)  # true = 1

      when 0x14 # OP_LOADFALSE (B)
        a = fetch_byte
        write_reg(a, 0)  # false = 0

      when 0x15 # OP_GETGV (BB)
        a = fetch_byte
        b = fetch_byte
        table_addr = DEVICE_TABLE_BASE + b * DEVICE_TABLE_STRIDE
        device_type = @em.read_u16(table_addr)
        device_addr = @em.read_u16(table_addr + 1)
        dev = device_memory(device_type)
        if dev
          if bit_device?(device_type)
            # ビットデバイス: 0 or 1 を読む
            write_reg(a, dev.read_u16(device_addr) != 0 ? 1 : 0)
          else
            write_reg(a, dev.read_s32(device_addr))
          end
        else
          @em.write_u16(STATUS_ADDR, VM_ERROR)
          @em.write_u16(ERROR_ADDR, 0x15)
        end

      when 0x16 # OP_SETGV (BB)
        a = fetch_byte
        b = fetch_byte
        val = read_reg(a)
        table_addr = DEVICE_TABLE_BASE + b * DEVICE_TABLE_STRIDE
        device_type = @em.read_u16(table_addr)
        device_addr = @em.read_u16(table_addr + 1)
        dev = device_memory(device_type)
        if dev
          if bit_device?(device_type)
            # ビットデバイス: 非0→1, 0→0
            dev.write_u16(device_addr, val != 0 ? 1 : 0)
          else
            dev.write_s32(device_addr, val)
          end
        else
          @em.write_u16(STATUS_ADDR, VM_ERROR)
          @em.write_u16(ERROR_ADDR, 0x16)
        end

      when 0x25 # OP_JMP (S)
        offset = fetch_s16
        @em.write_u16(PC_ADDR, pc + offset)

      when 0x26 # OP_JMPIF (BS)
        a = fetch_byte
        offset = fetch_s16
        if read_reg(a) != 0
          @em.write_u16(PC_ADDR, pc + offset)
        end

      when 0x27 # OP_JMPNOT (BS)
        a = fetch_byte
        offset = fetch_s16
        if read_reg(a) == 0
          @em.write_u16(PC_ADDR, pc + offset)
        end

      when 0x28 # OP_JMPNIL (BS)
        a = fetch_byte
        offset = fetch_s16
        if read_reg(a) == 0
          @em.write_u16(PC_ADDR, pc + offset)
        end

      when 0x38 # OP_RETURN (B)
        _a = fetch_byte
        # トップレベルでは VM 停止
        @em.write_u16(STATUS_ADDR, VM_FINISHED)

      when 0x3C # OP_ADD (B)
        a = fetch_byte
        result = read_reg(a) + read_reg(a + 1)
        write_reg(a, result)

      when 0x3D # OP_ADDI (BB)
        a = fetch_byte
        b = fetch_byte
        write_reg(a, read_reg(a) + b)

      when 0x3E # OP_SUB (B)
        a = fetch_byte
        result = read_reg(a) - read_reg(a + 1)
        write_reg(a, result)

      when 0x3F # OP_SUBI (BB)
        a = fetch_byte
        b = fetch_byte
        write_reg(a, read_reg(a) - b)

      when 0x40 # OP_MUL (B)
        a = fetch_byte
        result = read_reg(a) * read_reg(a + 1)
        write_reg(a, result)

      when 0x41 # OP_DIV (B)
        a = fetch_byte
        divisor = read_reg(a + 1)
        if divisor == 0
          @em.write_u16(STATUS_ADDR, VM_ERROR)
          @em.write_u16(ERROR_ADDR, 1)  # division by zero
        else
          result = read_reg(a) / divisor
          write_reg(a, result)
        end

      when 0x42 # OP_EQ (B)
        a = fetch_byte
        write_reg(a, read_reg(a) == read_reg(a + 1) ? 1 : 0)

      when 0x43 # OP_LT (B)
        a = fetch_byte
        write_reg(a, read_reg(a) < read_reg(a + 1) ? 1 : 0)

      when 0x44 # OP_LE (B)
        a = fetch_byte
        write_reg(a, read_reg(a) <= read_reg(a + 1) ? 1 : 0)

      when 0x45 # OP_GT (B)
        a = fetch_byte
        write_reg(a, read_reg(a) > read_reg(a + 1) ? 1 : 0)

      when 0x46 # OP_GE (B)
        a = fetch_byte
        write_reg(a, read_reg(a) >= read_reg(a + 1) ? 1 : 0)

      when 0x69 # OP_STOP (Z)
        @em.write_u16(STATUS_ADDR, VM_FINISHED)

      else
        # 未実装オペコード
        @em.write_u16(STATUS_ADDR, VM_ERROR)
        @em.write_u16(ERROR_ADDR, opcode)
      end
    end

    # バイトコードから1バイトフェッチし、PC を進める
    def fetch_byte
      current_pc = @em.read_u16(PC_ADDR)
      val = @em.read_u16(MemoryMap.bytecode_addr(current_pc))
      @em.write_u16(PC_ADDR, current_pc + 1)
      val & 0xFF
    end

    # 16ビット符号付き値をフェッチ (ビッグエンディアン)
    def fetch_s16
      hi = fetch_byte
      lo = fetch_byte
      val = (hi << 8) | lo
      val >= 32768 ? val - 65536 : val
    end

    # 16ビット符号なし値をフェッチ (ビッグエンディアン)
    def fetch_u16
      hi = fetch_byte
      lo = fetch_byte
      (hi << 8) | lo
    end

    # VM レジスタ読み取り
    def read_reg(n)
      @em.read_s32(MemoryMap.reg_addr(n))
    end

    # VM レジスタ書き込み
    def write_reg(n, val)
      @em.write_s32(MemoryMap.reg_addr(n), val)
    end

    # ビットデバイスかどうか判定
    def bit_device?(type)
      BIT_DEVICE_TYPES.include?(type)
    end

    # デバイスタイプに対応するメモリを返す
    def device_memory(type)
      @devices[type] if type >= 0 && type < @devices.size
    end
  end
end

# コマンドラインから実行した場合
if __FILE__ == $0
  if ARGV.empty?
    puts "Usage: ruby kv_vm_simulator.rb <file.mrb>"
    exit 1
  end

  data = File.binread(ARGV[0])
  parser = MrubycOnPlc::MrbParser.new(data).parse

  puts "=== Disassembly ==="
  disasm = MrubycOnPlc::Disassembler.new(parser.irep)
  puts disasm.disassemble_to_s
  puts

  sim = MrubycOnPlc::KvVmSimulator.new
  steps = sim.load_irep_and_run(parser.irep)

  puts "Executed #{steps} instructions"
  puts
  sim.dump_status
  puts
  sim.dump_registers
end
