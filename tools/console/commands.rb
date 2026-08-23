# frozen_string_literal: true

# コンソールコマンド定義
# 各コマンドの実行ロジックを定義します。

require_relative "../mrb_parser"
require_relative "../disasm"
require_relative "../plc_codegen"
require_relative "../vm_constants"
require_relative "../memory_layout"
require_relative "../../simulator/kv_vm_simulator"

module FaRuby
  module Console
    class Commands
      include VmConstants

      # 操作対象のインスタンス番号
      #
      # インスタンスごとに別のプログラムが動くため、compile/load/run/status は
      # すべてここで選んだインスタンスに対して行われます。
      attr_reader :instance

      def initialize(config:, adapter:, transfer:)
        @config = config
        @adapter = adapter
        @transfer = transfer
        @instance = 0
        @last_irep = nil
        @last_source = nil
        @last_disasm = nil
        @last_symbols = nil
        @last_sim = nil
      end

      # 選択中インスタンスの配置
      def layout = @config.layout.for_instance(@instance)

      # 操作対象を切り替える
      def instance=(index)
        @instance = Integer(index)
        @transfer.layout = layout
      end

      # instance [n]
      def cmd_instance(args)
        total = @config.layout.instances

        if args.empty?
          puts "=== インスタンス ==="
          total.times do |i|
            block = @config.layout.for_instance(i)
            mark = i == @instance ? "*" : " "
            puts format("%s %d  %s-%s", mark, i,
                        block.device(block.origin), block.device(block.block_last_addr))
          end
          puts ""
          puts "  * が操作対象。切り替えは `instance <番号>`。"
          return
        end

        index = args[0].to_i
        unless index.between?(0, total - 1)
          puts "ERROR: インスタンス番号は 0-#{total - 1} です"
          puts "  同時に動かす数は faruby.yml の memory.instances で決まります " \
               "(現在 #{total})。"
          return
        end

        self.instance = index
        puts "OK: インスタンス #{index} を操作対象にしました (#{layout.device(layout.origin)}~)"
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

        codegen = PlcCodegen.new(@last_irep, steps_per_cycle: @config.steps_per_cycle, layout: layout)
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
          puts "  R[#{r[:index]}] = #{r[:display] || r[:value]}\t(#{r[:label]})"
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

        codegen = PlcCodegen.new(@last_irep, steps_per_cycle: @config.steps_per_cycle, layout: layout)
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
            puts "  %-8d  %-10s  %-10d  %-10d" % [m[:addr], layout.device(m[:addr]), m[:expected], m[:actual]]
          end
        end
      end

      # memmap
      def cmd_memmap(args)
        puts "=== メモリ配置 ==="
        puts "  設定: #{@config.config_path || '(既定のみ)'}"
        puts "  全体: #{layout}"
        puts ""

        if @config.layout.instances > 1
          puts "  インスタンス:"
          @config.layout.instances.times do |i|
            block = @config.layout.for_instance(i)
            mark = i == @instance ? "*" : " "
            puts format("  %s %d  %s-%s", mark, i,
                        block.device(block.origin), block.device(block.block_last_addr))
          end
          puts ""
          puts "  以下はインスタンス #{@instance} の内訳:"
        end

        puts format("  %-20s %-10s %-10s %s", "領域", "開始", "終了", "ワード数")
        puts "  #{'-' * 52}"
        layout.regions.each do |name, from, to, words|
          puts format("  %-20s %-10s %-10s %d", name, layout.device(from), layout.device(to), words)
        end
        puts ""
        puts "  ラダーがこの範囲を使用していないことを確認してください。"
        puts "  範囲を変えるには faruby.yml の memory 節を編集し、"
        puts "  `rake vm_core` で再生成して KV Studio に取り込み直します。"
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
        @last_sim = KvVmSimulator.new(layout: layout)
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
        codegen = PlcCodegen.new(@last_irep, steps_per_cycle: @config.steps_per_cycle, layout: layout)

        # 割り当ては codegen と同一のロジックを使う (汎用グローバルの採番を含む)
        codegen.device_mappings.each do |m|
          bit = m[:bit]
          kind = bit ? "ビット" : ACCESS_NAMES[m[:access_type]]

          val = read_global_value(m[:device_name], m[:address], m[:z_offset], bit, m[:access_type])
          puts format("  %-12s = %-10s (%s, addr=%s, %s)", m[:symbol], val.nil? ? "?" : val.to_s, m[:device_name], m[:address], kind)
        end
      end

      # dev <device> [value]
      def cmd_dev(args)
        if args.empty?
          puts "Usage: dev <device> [value]"
          puts "  例: dev DM100       DM100 を16ビット符号付きで読む"
          puts "  例: dev DM100L      DM100 を32ビット符号付きで読む"
          puts "  例: dev DM100 42    DM100 に 42 を書き込む"
          puts "  幅サフィックス: S=16bit符号付き(既定) U=16bit符号なし L=32bit符号付き D=32bit符号なし"
          return
        end

        parsed = PlcCodegen.parse_device_name(args[0])
        unless parsed
          puts "ERROR: 不明なデバイス: #{args[0]}"
          puts "  対応デバイス: EM, DM, ZF (幅サフィックス可), R, MR, B, L, T, C"
          return
        end

        dev_name = parsed[:device_name]
        dev_addr = parsed[:address]
        z_offset = parsed[:z_offset]
        dev_type = parsed[:device_type]
        bit = parsed[:bit]
        access_type = parsed[:access_type] || ACCESS_S

        if args[1]
          # 書き込み
          value = args[1].to_i
          write_device_value(dev_name, dev_addr, z_offset, dev_type, bit, value, access_type)
          puts "#{dev_name}#{dev_addr} <- #{value}"
        else
          # 読み取り
          val = read_device_value(dev_name, dev_addr, z_offset, dev_type, bit, access_type)
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

        # IP アドレス等は既定値を持てないため、接続前に検証する
        @config.validate_connection!
        @adapter.connect
        puts "OK: #{@config.plc_protocol} @ #{@config.plc_host}:#{@config.plc_port} に接続しました"
      end

      # help
      def cmd_help(args)
        puts <<~HELP
          === faRuby Console ===
          compile <file.rb>  Ruby ソースをコンパイル
          load               コンパイル済みプログラムを PLC に書き込み
          run                VM を開始 (STATUS=1)
          instance [n]       操作対象のインスタンスを表示 / 切り替え
          status             VM 状態を表示
          regs [count]       レジスタ値を表示
          vars               グローバル変数の値を表示
          dev <device> [val] デバイスの読み書き (例: dev DM100)
                             ワードは幅サフィックス可 (DM100L 等)
          stop               VM を停止 (STATUS=0)
          reset              VM をリセット
          verify             PLC メモリとバイナリを比較
          memmap             メモリ配置を表示
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
      def read_global_value(dev_name, dev_addr, z_offset, bit, access_type = ACCESS_S)
        dev_type = PlcCodegen::DEVICE_NAME_TO_TYPE[dev_name]
        read_device_value(dev_name, dev_addr, z_offset, dev_type, bit, access_type)
      end

      # デバイス値の読み取り (dev / vars コマンド用)
      # ワードデバイスは VM と同じアクセス幅で読む
      def read_device_value(dev_name, dev_addr, z_offset, dev_type, bit, access_type = ACCESS_S)
        if @last_sim
          dev = @last_sim.devices[dev_type]
          return nil unless dev
          return dev.read_u16(z_offset) if bit

          case access_type
          when ACCESS_U then dev.read_u16(z_offset)
          when ACCESS_L then dev.read_s32(z_offset)
          when ACCESS_D then dev.read_u32(z_offset)
          when ACCESS_F then [dev.read_u32(z_offset)].pack("V").unpack1("e")
          else               dev.read_s16(z_offset)
          end
        elsif @adapter.connected?
          return @adapter.read_device(dev_name, dev_addr) if bit

          @adapter.read_device_width(dev_name, dev_addr, access_type)
        end
      end

      # デバイス値の書き込み (dev コマンド用)
      # ワードデバイスは VM と同じアクセス幅で書く
      def write_device_value(dev_name, dev_addr, z_offset, dev_type, bit, value, access_type = ACCESS_S)
        if @last_sim
          dev = @last_sim.devices[dev_type]
          return unless dev

          if bit
            dev.write_u16(z_offset, value != 0 ? 1 : 0)
          else
            case access_type
            when ACCESS_U then dev.write_u16(z_offset, value)
            when ACCESS_L then dev.write_s32(z_offset, value)
            when ACCESS_D then dev.write_u32(z_offset, value)
            when ACCESS_F then dev.write_u32(z_offset, [value.to_f].pack("e").unpack1("V"))
            else               dev.write_s16(z_offset, value)
            end
          end
        elsif @adapter.connected?
          if bit
            @adapter.write_device(dev_name, dev_addr, value)
          else
            @adapter.write_device_width(dev_name, dev_addr, access_type, value)
          end
        else
          puts "ERROR: PLC 未接続、sim 未実行"
        end
      end
    end
  end
end
