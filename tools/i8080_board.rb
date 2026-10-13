# frozen_string_literal: true

# r8080 エミュレータのラッパー
#
# Intel HEX を読み込み、i8080 VM を実行して結果を返す。
# テストと対話的な検証に使います。
#
# 依存: r8080 リポジトリ (外部)
#   https://github.com/kito/r8080

require_relative "i8080_memory_layout"
require_relative "vm_constants"

module FaRuby
  class I8080Board
    include VmConstants

    Layout = I8080MemoryLayout

    # r8080 のパス (環境変数 R8080_PATH か、隣のリポジトリ)
    R8080_LIB = ENV.fetch("R8080_PATH") {
      File.expand_path("../../r8080/lib", __dir__)
    }

    def initialize
      load_r8080
      @cpu = I8080.new
      @halted = false
    end

    # Intel HEX ファイルをメモリに読み込む
    def load_hex(path)
      data = IntelHex.load(path)
      data.each_with_index do |byte, addr|
        @cpu.mem[addr] = byte if byte
      end
    end

    # バイト列を指定アドレスから直接書き込む
    def write_memory(addr, bytes)
      bytes.each_with_index do |byte, i|
        @cpu.mem[addr + i] = byte
      end
    end

    # メモリから読み出す
    def read_memory(addr, length = 1)
      (0...length).map { |i| @cpu.mem[addr + i] }
    end

    # 16 ビット値を読む (リトルエンディアン)
    def read_u16(addr)
      @cpu.mem[addr] | (@cpu.mem[addr + 1] << 8)
    end

    # 32 ビット値を読む (リトルエンディアン)
    def read_u32(addr)
      read_u16(addr) | (read_u16(addr + 2) << 16)
    end

    # CPU をリセットして実行する
    #
    # max_steps: 最大命令数 (無限ループ防止)
    # 戻り値: 停止理由 (:finished, :error, :timeout, :halted)
    def run(max_steps: 2_000_000)
      @cpu.reset
      @cpu.pc = Layout::VM_CODE_ORG
      @halted = false
      steps = 0

      while steps < max_steps
        old_pc = @cpu.pc
        @cpu.send(:execute)

        # 停止検出:
        # 1) HLT: PC が進まない
        # 2) ROM 領域へのジャンプ: モニタ復帰 (実機では NDZENT1 等)
        if @cpu.pc == old_pc || @cpu.pc < Layout::RAM_BASE
          @halted = true
          break
        end

        steps += 1
      end

      return :timeout unless @halted

      status = vm_status
      case status
      when VM_FINISHED then :finished
      when VM_ERROR    then :error
      else                  :halted
      end
    end

    # --- VM 状態の読み出し ---

    def vm_status
      @cpu.mem[Layout::VM_STATE_BASE + Layout::OFFSET_STATUS]
    end

    def vm_error_code
      read_u16(Layout::VM_STATE_BASE + Layout::OFFSET_ERROR)
    end

    def vm_pc
      read_u16(Layout::VM_STATE_BASE + Layout::OFFSET_PC)
    end

    def vm_step_count
      read_u32(Layout::VM_STATE_BASE + Layout::OFFSET_STEP_COUNT)
    end

    # --- レジスタの読み出し ---

    # レジスタの型タグ
    def reg_type(index)
      addr = Layout.reg_type_addr(index)
      @cpu.mem[addr]
    end

    # レジスタの値 (16 ビット符号付き整数として解釈)
    def reg_value(index)
      addr = Layout.reg_value_addr(index)
      val = read_u16(addr)
      # 符号付きに変換
      val >= 0x8000 ? val - 0x10000 : val
    end

    # レジスタの内容を読みやすい形で返す
    def reg_inspect(index)
      type = reg_type(index)
      case type
      when TT_EMPTY   then "empty"
      when TT_NIL     then "nil"
      when TT_FALSE   then "false"
      when TT_TRUE    then "true"
      when TT_INTEGER then reg_value(index).to_s
      else "type=#{type} val=#{reg_value(index)}"
      end
    end

    # --- 7 セグ表示の読み出し ---

    # 表示バッファの生バイト列
    def display_raw
      read_memory(Layout::DISPLAY_BASE, Layout::DISPLAY_SIZE)
    end

    # 表示バッファをセグメントパターンから 16 進文字に変換
    SEG_TO_HEX = {
      0x00 => " ", 0x5C => "0", 0x06 => "1", 0x5B => "2", 0x4F => "3",
      0x66 => "4", 0x6D => "5", 0x7D => "6", 0x27 => "7",
      0x7F => "8", 0x6F => "9", 0x77 => "A", 0x7C => "b",
      0x39 => "C", 0x5E => "d", 0x79 => "E", 0x71 => "F",
    }.freeze

    def display_text
      display_raw.map { |seg| SEG_TO_HEX[seg] || "?" }.join
    end

    # 7 セグ表示を ASCII アートで描画する (3 行)
    #
    #   _     _   _       _   _   _   _   _
    #  | |  | _| _| |_| |_  |_    | |_| |_|
    #  |_|  | |_  _|   |  _| |_|  | |_|  _|
    #
    def display_ascii
      segs = display_raw
      lines = Array.new(3) { +"" }
      segs.each_with_index do |s, i|
        a = s[0] == 1; b = s[1] == 1; c = s[2] == 1
        d = s[3] == 1; e = s[4] == 1; f = s[5] == 1
        g = s[6] == 1
        lines[0] << " " << (a ? "_" : " ") << " "
        lines[1] << (f ? "|" : " ") << (g ? "_" : " ") << (b ? "|" : " ")
        lines[2] << (e ? "|" : " ") << (d ? "_" : " ") << (c ? "|" : " ")
        unless i == segs.size - 1
          lines.each { |l| l << " " }
        end
      end
      lines.join("\n")
    end

    # --- デバッグ ---

    def dump_state
      <<~TEXT
        VM Status: #{vm_status} (#{%w[STOPPED RUNNING FINISHED ERROR][vm_status] || "?"})
        VM PC: #{vm_pc}
        Steps: #{vm_step_count}
        Error: #{vm_error_code}
        Display: #{display_text}
        #{display_ascii}
        Registers:
        #{(0..7).map { |i| "  R[#{i}] = #{reg_inspect(i)}" }.join("\n")}
      TEXT
    end

    private

    def load_r8080
      $LOAD_PATH.unshift(R8080_LIB) unless $LOAD_PATH.include?(R8080_LIB)
      require "i8080"
      require "intel_hex"
    end
  end
end

# 直接実行: HEX ファイルを読み込んで実行し、結果を表示する
if $PROGRAM_NAME == __FILE__
  hex_path = ARGV[0]
  unless hex_path
    warn "使い方: ruby #{$PROGRAM_NAME} combined.hex"
    exit 1
  end

  board = FaRuby::I8080Board.new
  board.load_hex(hex_path)
  result = board.run
  puts "Result: #{result}"
  puts board.dump_state
end
