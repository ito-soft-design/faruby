# frozen_string_literal: true

# KV スクリプト VM シミュレータ
#
# PLC 上の KV スクリプト VM と同一ロジックで動作する PC 側シミュレータです。
# 命令の意味は tools/opcode_table.rb の定義表に一本化されており、
# ここではフェッチとディスパッチだけを行います。実際の解釈は SimVm が担います。
# PLC 側 (vm_core.kvs) も同じ定義表から生成されるため、片方にだけ命令がある
# といった食い違いは構造的に起きません。

require_relative "em_memory"
require_relative "sim_vm"
require_relative "../tools/memory_map"
require_relative "../tools/opcode_table"
require_relative "../tools/mrb_parser"
require_relative "../tools/disasm"
require_relative "../tools/plc_codegen"

module MrubycOnPlc
  class KvVmSimulator
    include MemoryMap

    # 後方互換: 以前はこの定数をシミュレータが持っていた
    BIT_DEVICE_TYPES = SimVm::BIT_DEVICE_TYPES

    attr_reader :em, :devices

    def initialize
      @em = EmMemory.new
      @devices = Array.new(10) { EmMemory.new }
      @devices[0] = @em  # EM はメインメモリを共用
      @vm = SimVm.new(@em, @devices)
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
      load_and_run(codegen.memory_image, max_steps: max_steps)
    end

    # グローバル変数の値をシンボル名で取得 (テスト用)
    def global_value(sym_name)
      return nil unless @irep

      idx = @irep.symbols.index(sym_name)
      return nil unless idx

      @vm.send(:device_entry, idx) => [device_type, device_addr, access_type]
      dev = @vm.send(:device_memory, device_type)
      return nil unless dev

      if @vm.send(:bit_device?, device_type)
        dev.read_u16(device_addr)
      else
        @vm.send(:read_word_device, dev, device_addr, access_type)
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
    def reg(n) = @em.read_s32(MemoryMap.reg_addr(n))

    def status = @em.read_u16(STATUS_ADDR)
    def pc     = @em.read_u16(PC_ADDR)

    # レジスタダンプ
    def dump_registers(count = nil)
      count ||= @em.read_u16(NREGS_ADDR)
      count = [count, MAX_REGS].min
      nlocals = @em.read_u16(NLOCALS_ADDR)
      puts "=== VM Registers ==="
      count.times do |i|
        label = case i
                when 0 then "(self)"
                when 1...nlocals then "(local)"
                else "(temp)"
                end
        puts format("  R[%d] = %d  %s", i, reg(i), label)
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

    # 1命令を実行する
    # フェッチ → 定義表を引く → SimVm で本体を実行、という流れは
    # vm_core.kvs の FETCH / DECODE / EXECUTE と同じ構造
    def execute_one_instruction
      opcode = @vm.fetch_byte
      @em.write_u16(CURRENT_OPCODE, opcode)

      op = OpcodeTable.lookup[opcode]
      unless op
        # 未実装オペコード (vm_core.kvs 側の ELSE 節に対応)
        @em.write_u16(STATUS_ADDR, VM_ERROR)
        @em.write_u16(ERROR_ADDR, opcode)
        return
      end

      @vm.begin_instruction(@vm.fetch_operands(op.operand_sizes))
      op.body&.call(@vm)
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
  puts MrubycOnPlc::Disassembler.new(parser.irep).disassemble_to_s
  puts

  sim = MrubycOnPlc::KvVmSimulator.new
  steps = sim.load_irep_and_run(parser.irep)

  puts "Executed #{steps} instructions"
  puts
  sim.dump_status
  puts
  sim.dump_registers
end
