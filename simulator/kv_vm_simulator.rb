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
require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/opcode_table"
require_relative "../tools/mrb_parser"
require_relative "../tools/disasm"
require_relative "../tools/plc_codegen"

module FaRuby
  class KvVmSimulator
    include VmConstants

    # 後方互換: 以前はこの定数をシミュレータが持っていた
    BIT_DEVICE_TYPES = SimVm::BIT_DEVICE_TYPES

    attr_reader :em, :devices, :layout

    def initialize(layout: MemoryLayout.default)
      @layout = layout
      @em = EmMemory.new
      # 固定領域 (実機では FM = バンク 3 の ZF)。
      # 利用者が $ZF500 を使う場合とアドレスが重ならないよう別のメモリにする
      @fixed = EmMemory.new
      @devices = Array.new(10) { EmMemory.new }
      @devices[0] = @em  # EM はメインメモリを共用
      @vm = SimVm.new(@em, @devices, layout: layout, fixed: @fixed)
      @irep = nil
      point_at_top_irep
    end

    attr_reader :fixed

    # 実行中の irep とレジスタ窓を既定の位置に向ける
    #
    # irep が複数になってから、バイトコード・定数プール・シンボル表・レジスタの
    # 位置は VM 状態から引くようになりました。メモリイメージを読まずにバイト
    # コードを直接置いて動かす場合 (テスト) もここで既定値が入ります。
    def point_at_top_irep
      # レジスタ窓は可変領域なのでブロック先頭からのオフセット。
      # 残りは固定領域 (FM) の絶対アドレス
      @em.write_u16(layout.reg_base_addr, layout.offset_of(layout.reg_file_base))
      { layout.cur_bytecode_addr => layout.bytecode_base,
        layout.cur_pool_addr     => layout.pool_base,
        layout.cur_symbols_addr  => layout.device_table_base,
        layout.irep_table_addr_addr => layout.irep_table_base }.each do |addr, target|
        @em.write_u16(addr, target)
      end
      @em.write_u16(layout.cur_irep_addr, 0)
      @em.write_u16(layout.frame_sp_addr, 0)
    end

    # メモリイメージをロードして実行
    def load_and_run(image, fixed_image = nil, max_steps: 10000)
      @em.load_image(image)
      @fixed.load_image(fixed_image) if fixed_image
      run(max_steps: max_steps)
    end

    # IREP から直接ロードして実行
    def load_irep_and_run(irep, max_steps: 10000)
      @irep = irep
      codegen = PlcCodegen.new(irep, steps_per_cycle: max_steps, layout: layout)
      load_and_run(codegen.memory_image, codegen.fixed_image, max_steps: max_steps)
    end

    # グローバル変数の値をシンボル名で取得 (テスト用)
    def global_value(sym_name)
      return nil unless @irep

      idx = @irep.symbols.index(sym_name)
      return nil unless idx

      @vm.send(:device_entry, idx) => [device_type, device_addr, access_type, *]
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
    def reg(n) = @em.read_s32(layout.reg_addr(n))

    def status = @em.read_u16(layout.status_addr)
    def pc     = @em.read_u16(layout.pc_addr)

    # レジスタダンプ
    def dump_registers(count = nil)
      count ||= @em.read_u16(layout.nregs_addr)
      count = [count, layout.max_regs].min
      nlocals = @em.read_u16(layout.nlocals_addr)
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
      puts "  ERROR  = #{@em.read_u16(layout.error_addr)}"
      puts "  OPCODE = #{@em.read_u16(layout.current_opcode_addr)}"
    end

    private

    # 1命令を実行する
    # フェッチ → 定義表を引く → SimVm で本体を実行、という流れは
    # vm_core.kvs の FETCH / DECODE / EXECUTE と同じ構造
    def execute_one_instruction
      opcode = @vm.fetch_byte
      @em.write_u16(layout.current_opcode_addr, opcode)

      op = OpcodeTable.lookup[opcode]
      unless op
        # 未実装オペコード (vm_core.kvs 側の ELSE 節に対応)
        @em.write_u16(layout.status_addr, VM_ERROR)
        @em.write_u16(layout.error_addr, opcode)
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
  parser = FaRuby::MrbParser.new(data).parse

  puts "=== Disassembly ==="
  puts FaRuby::Disassembler.new(parser.irep).disassemble_to_s
  puts

  sim = FaRuby::KvVmSimulator.new
  steps = sim.load_irep_and_run(parser.irep)

  puts "Executed #{steps} instructions"
  puts
  sim.dump_status
  puts
  sim.dump_registers
end
