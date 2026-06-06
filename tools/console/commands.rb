# frozen_string_literal: true

# コンソールコマンド定義
# 各コマンドの実行ロジックを定義します。

require_relative "../mrb_parser"
require_relative "../disasm"
require_relative "../plc_codegen"
require_relative "../memory_map"
require_relative "../../simulator/kv_vm_simulator"

module MrubycOnPlc
  module Console
    class Commands
      include MemoryMap

      def initialize(config:, adapter:, transfer:)
        @config = config
        @adapter = adapter
        @transfer = transfer
        @last_irep = nil
        @last_source = nil
        @last_disasm = nil
        @last_symbols = nil
      end

      # compile <file.rb>
      def cmd_compile(args)
        source = args[0]
        unless source
          puts "Usage: compile <file.rb>"
          return
        end

        unless File.exist?(source)
          puts "ERROR: ファイルが見つかりません: #{source}"
          return
        end

        # mrbc でコンパイル
        mrb_path = source.sub(/\.rb$/, ".mrb")
        puts "Compiling: #{source}"
        result = system(@config.mrbc_path, "-o", mrb_path, source)
        unless result
          puts "ERROR: mrbc コンパイル失敗"
          return
        end

        # RITE バイナリをパース
        data = File.binread(mrb_path)
        parsed = MrbParser.new(data).parse
        @last_irep = parsed.irep
        @last_source = source
        @last_symbols = parsed.irep.symbols

        # 逆アセンブル結果をキャッシュ
        disasm = Disassembler.new(@last_irep)
        @last_disasm = disasm.disassemble_to_s

        # 一時ファイル削除
        File.delete(mrb_path) if File.exist?(mrb_path)

        puts "OK: nlocals=#{@last_irep.nlocals}, nregs=#{@last_irep.nregs}, " \
             "ilen=#{@last_irep.ilen}, pool=#{@last_irep.pool.size}, " \
             "syms=#{@last_irep.symbols.size}"
        puts "Symbols: #{@last_irep.symbols.inspect}" unless @last_irep.symbols.empty?
      end

      # load
      def cmd_load(args)
        unless @last_irep
          puts "ERROR: 先に compile を実行してください"
          return
        end

        codegen = PlcCodegen.new(@last_irep, steps_per_cycle: @config.steps_per_cycle)
        image = codegen.memory_image
        count = @transfer.write_image(image)
        puts "OK: #{count} ワードを PLC に書き込みました"
        puts "  バイトコード: #{@last_irep.ilen} バイト"
        puts "  定数プール: #{@last_irep.pool.size} エントリ"
        puts "  レジスタ: #{@last_irep.nregs} 個"
      end

      # run
      def cmd_run(args)
        @transfer.write_status(VM_RUNNING)
        puts "OK: VM を開始しました (STATUS=1)"
      end

      # status
      def cmd_status(args)
        state = @transfer.read_vm_state
        puts "=== VM Status ==="
        puts "  STATUS : #{state[:status]} (#{state[:status_label]})"
        puts "  PC     : #{state[:pc]}"
        puts "  ERROR  : #{state[:error]}"
        puts "  STEPS  : #{state[:step_count]}"
        puts "  OPCODE : #{state[:current_opcode]}"
        puts "  ARGS   : a=#{state[:operand_a]} b=#{state[:operand_b]} c=#{state[:operand_c]}"
        puts "  BCLEN  : #{state[:bytecode_len]}"
        puts "  NREGS  : #{state[:nregs]}"
        puts "  NLOCALS: #{state[:nlocals]}"
      end

      # regs [count]
      def cmd_regs(args)
        count = args[0]&.to_i
        regs = if count
                 @transfer.read_registers(count)
               else
                 @transfer.read_registers
               end

        puts "=== Registers ==="
        regs.each do |r|
          puts "  R[#{r[:index]}] = #{r[:value]}\t(#{r[:label]})"
        end
      end

      # stop
      def cmd_stop(args)
        @transfer.write_status(VM_STOPPED)
        puts "OK: VM を停止しました (STATUS=0)"
      end

      # reset
      def cmd_reset(args)
        @transfer.reset_vm(steps_per_cycle: @config.steps_per_cycle)
        puts "OK: VM をリセットしました"
      end

      # disasm
      def cmd_disasm(args)
        unless @last_disasm
          puts "ERROR: 先に compile を実行してください"
          return
        end

        puts "=== Disassembly: #{@last_source} ==="
        puts @last_disasm
      end

      # sim
      def cmd_sim(args)
        unless @last_irep
          puts "ERROR: 先に compile を実行してください"
          return
        end

        puts "=== Simulator ==="
        sim = KvVmSimulator.new
        steps = sim.load_irep_and_run(@last_irep)
        puts "#{steps} 命令実行"
        puts
        sim.dump_status
        puts
        sim.dump_registers
      end

      # connect
      def cmd_connect(args)
        if @adapter.connected?
          puts "既に接続されています"
          return
        end

        @adapter.connect
        puts "OK: #{@config.plc_protocol} @ #{@config.plc_host}:#{@config.plc_port} に接続しました"
      end

      # help
      def cmd_help(args)
        puts <<~HELP
          === mruby/c on PLC Console ===
          compile <file.rb>  Ruby ソースをコンパイル
          load               コンパイル済みプログラムを PLC に書き込み
          run                VM を開始 (STATUS=1)
          status             VM 状態を表示
          regs [count]       レジスタ値を表示
          stop               VM を停止 (STATUS=0)
          reset              VM をリセット
          disasm             逆アセンブリ表示
          sim                シミュレータで実行
          connect            PLC に接続
          help               このヘルプを表示
          quit               終了
        HELP
      end
    end
  end
end
