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
        @last_sim = nil
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
        puts "  STATUS   : #{state[:status]} (#{state[:status_label]})"
        puts "  PC       : #{state[:pc]}"
        puts "  ERROR    : #{state[:error]}"
        puts "  STEPS    : #{state[:step_count]}"
        puts "  OPCODE   : #{state[:current_opcode]}"
        puts "  ARGS     : a=#{state[:operand_a]} b=#{state[:operand_b]} c=#{state[:operand_c]}"
        puts "  BCLEN    : #{state[:bytecode_len]}"
        puts "  NREGS    : #{state[:nregs]}"
        puts "  NLOCALS  : #{state[:nlocals]}"
        puts "  RESET_REQ: #{state[:reset_req]}" if state[:reset_req] != 0
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
        @transfer.request_reset
        puts "OK: リセット要求を送信しました (RESET_REQ=1)"
      end

      # verify
      def cmd_verify(args)
        unless @last_irep
          puts "ERROR: 先に compile を実行してください"
          return
        end

        codegen = PlcCodegen.new(@last_irep, steps_per_cycle: @config.steps_per_cycle)
        image = codegen.memory_image

        result = @transfer.verify_image(image)

        if result[:match]
          puts "OK: PLC メモリと一致 (#{result[:total]} ワード)"
        else
          puts "NG: #{result[:mismatches].size} / #{result[:total]} ワード不一致"
          puts ""
          puts "  %-8s  %-10s  %-10s  %-10s" % ["ADDR", "DEVICE", "EXPECTED", "ACTUAL"]
          puts "  #{'-' * 42}"
          result[:mismatches].each do |m|
            puts "  %-8d  %-10s  %-10d  %-10d" % [m[:addr], MemoryMap.device(m[:addr]), m[:expected], m[:actual]]
          end
        end
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
        @last_sim = KvVmSimulator.new
        steps = @last_sim.load_irep_and_run(@last_irep)
        puts "#{steps} 命令実行"
        puts
        @last_sim.dump_status
        puts
        @last_sim.dump_registers
      end

      # vars
      def cmd_vars(args)
        unless @last_irep
          puts "ERROR: 先に compile を実行してください"
          return
        end

        symbols = @last_irep.symbols
        if symbols.empty?
          puts "グローバル変数はありません"
          return
        end

        puts "=== Global Variables ==="
        codegen = PlcCodegen.new(@last_irep, steps_per_cycle: @config.steps_per_cycle)

        symbols.each_with_index do |sym, idx|
          parsed = PlcCodegen.parse_device_symbol(sym)
          if parsed
            dev_name = parsed[:device_name]
            dev_addr = parsed[:address]
            z_offset = parsed[:z_offset]
            dev_type = parsed[:device_type]
            bit = KvVmSimulator::BIT_DEVICE_TYPES.include?(dev_type)
            kind = bit ? "ビット" : "ワード"
          else
            dev_name = "EM"
            dev_addr = (GENERAL_GLOBAL_BASE + idx * 2).to_s
            z_offset = GENERAL_GLOBAL_BASE + idx * 2
            bit = false
            kind = "ワード"
          end

          val = read_global_value(dev_name, dev_addr, z_offset, bit)
          puts format("  %-12s = %-10s (%s, addr=%s, %s)", sym, val.nil? ? "?" : val.to_s, dev_name, dev_addr, kind)
        end
      end

      # dev <device> [value]
      def cmd_dev(args)
        if args.empty?
          puts "Usage: dev <device> [value]"
          puts "  例: dev DM100       DM100 の値を読む"
          puts "  例: dev DM100 42    DM100 に 42 を書き込む"
          return
        end

        parsed = PlcCodegen.parse_device_name(args[0])
        unless parsed
          puts "ERROR: 不明なデバイス: #{args[0]}"
          puts "  対応デバイス: EM, DM, ZF, R, MR, B, L, T, C"
          return
        end

        dev_name = parsed[:device_name]
        dev_addr = parsed[:address]
        z_offset = parsed[:z_offset]
        dev_type = parsed[:device_type]
        bit = KvVmSimulator::BIT_DEVICE_TYPES.include?(dev_type)

        if args[1]
          # 書き込み
          value = args[1].to_i
          write_device_value(dev_name, dev_addr, z_offset, dev_type, bit, value)
          puts "#{dev_name}#{dev_addr} <- #{value}"
        else
          # 読み取り
          val = read_device_value(dev_name, dev_addr, z_offset, dev_type, bit)
          if val.nil?
            puts "ERROR: 値を読み取れません (PLC 未接続、sim 未実行)"
          else
            puts "#{dev_name}#{dev_addr} = #{val}"
          end
        end
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
          vars               グローバル変数の値を表示
          dev <device> [val] デバイスの読み書き (例: dev DM100)
          stop               VM を停止 (STATUS=0)
          reset              VM をリセット
          verify             PLC メモリとバイナリを比較
          disasm             逆アセンブリ表示
          sim                シミュレータで実行
          connect            PLC に接続
          help               このヘルプを表示
          quit               終了
        HELP
      end

      private

      # グローバル変数の値を読む (vars コマンド用)
      # dev_addr: 元のアドレス文字列 (PLC 通信用)
      # z_offset: Z レジスタ用オフセット (シミュレータ用)
      def read_global_value(dev_name, dev_addr, z_offset, bit)
        if @last_sim
          # シミュレータから読む
          dev_type = PlcCodegen::DEVICE_NAME_TO_TYPE[dev_name]
          dev = @last_sim.send(:device_memory, dev_type)
          return nil unless dev
          bit ? dev.read_u16(z_offset) : dev.read_s32(z_offset)
        elsif @adapter.connected?
          @adapter.read_device(dev_name, dev_addr)
        end
      end

      # デバイス値の読み取り (dev コマンド用)
      def read_device_value(dev_name, dev_addr, z_offset, dev_type, bit)
        if @last_sim
          dev = @last_sim.send(:device_memory, dev_type)
          return nil unless dev
          bit ? dev.read_u16(z_offset) : dev.read_s32(z_offset)
        elsif @adapter.connected?
          @adapter.read_device(dev_name, dev_addr)
        end
      end

      # デバイス値の書き込み (dev コマンド用)
      def write_device_value(dev_name, dev_addr, z_offset, dev_type, bit, value)
        if @last_sim
          dev = @last_sim.send(:device_memory, dev_type)
          if dev
            if bit
              dev.write_u16(z_offset, value != 0 ? 1 : 0)
            else
              dev.write_s32(z_offset, value)
            end
          end
        elsif @adapter.connected?
          @adapter.write_device(dev_name, dev_addr, value)
        else
          puts "ERROR: PLC 未接続、sim 未実行"
        end
      end
    end
  end
end
