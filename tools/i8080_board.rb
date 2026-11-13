# frozen_string_literal: true

# r8080 エミュレータのラッパー
#
# Intel HEX を読み込み、i8080 VM を実行して結果を返す。
# テストと対話的な検証に使います。
#
# 依存: r8080 リポジトリ (外部)
#   https://github.com/katsuyoshi/r8080

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
      when TT_STRING  then reg_string(index).inspect
      when TT_ARRAY   then reg_array(index).inspect
      when TT_HASH    then reg_hash(index).inspect
      else "type=#{type} val=#{reg_value(index)}"
      end
    end

    # --- コレクションプールの読み出し ---

    # コレクションスロットのアドレス (0-based)
    def col_slot_addr(slot)
      Layout::COLLECTION_POOL_BASE + slot * Layout::COL_SLOT_SIZE
    end

    # コレクションスロットから文字列を読む
    def col_string(slot)
      addr = col_slot_addr(slot)
      count = @cpu.mem[addr + 1]
      (0...count).map { |i| @cpu.mem[addr + 2 + i] }.pack("C*")
    end

    # コレクションスロットから配列を読む (各要素を [type, value] で返す)
    def col_array_raw(slot)
      addr = col_slot_addr(slot)
      count = @cpu.mem[addr + 1]
      (0...count).map do |i|
        elem_addr = addr + 2 + i * Layout::SLOT_BYTES
        type = @cpu.mem[elem_addr]
        val = @cpu.mem[elem_addr + 2] | (@cpu.mem[elem_addr + 3] << 8)
        val = val - 0x10000 if type == TT_INTEGER && val >= 0x8000
        [type, val]
      end
    end

    # コレクションスロットから Hash を読む (各ペアを {key: [type, val], value: [type, val]} で返す)
    def col_hash_raw(slot)
      addr = col_slot_addr(slot)
      count = @cpu.mem[addr + 1]
      (0...count).map do |i|
        pair_addr = addr + 2 + i * Layout::HASH_PAIR_BYTES
        key_type = @cpu.mem[pair_addr]
        key_val = @cpu.mem[pair_addr + 2] | (@cpu.mem[pair_addr + 3] << 8)
        key_val = key_val - 0x10000 if key_type == TT_INTEGER && key_val >= 0x8000
        val_type = @cpu.mem[pair_addr + 4]
        val_val = @cpu.mem[pair_addr + 6] | (@cpu.mem[pair_addr + 7] << 8)
        val_val = val_val - 0x10000 if val_type == TT_INTEGER && val_val >= 0x8000
        { key: [key_type, key_val], value: [val_type, val_val] }
      end
    end

    # レジスタが TT_STRING のとき文字列を返す
    def reg_string(index)
      slot_num = reg_value(index) - 1  # val_lo = slot+1
      col_string(slot_num)
    end

    # レジスタが TT_ARRAY のとき要素の値を配列で返す (整数のみ簡易)
    def reg_array(index)
      slot_num = reg_value(index) - 1
      col_array_raw(slot_num).map do |type, val|
        case type
        when TT_INTEGER then val
        when TT_STRING  then col_string(val - 1)
        when TT_NIL     then nil
        when TT_TRUE    then true
        when TT_FALSE   then false
        else [type, val]
        end
      end
    end

    # レジスタが TT_HASH のとき Ruby Hash として返す
    def reg_hash(index)
      slot_num = reg_value(index) - 1
      result = {}
      col_hash_raw(slot_num).each do |pair|
        key = slot_to_ruby(pair[:key][0], pair[:key][1])
        value = slot_to_ruby(pair[:value][0], pair[:value][1])
        result[key] = value
      end
      result
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

    # セグメントパターン → ASCII 文字 (拡張版)
    #
    # ascii_seg_table (vm_main.a80) の全エントリの逆引きテーブル。
    # SEG_TO_HEX は hex 16 文字だけだが、こちらは英字・記号を含む。
    # 同じパターンに複数の文字が対応する場合は代表的な方を優先する。
    SEG_TO_ASCII = {
      0x00 => " ",
      0x06 => "1",  # 'I', '!' も同じパターンだが '1' を優先
      0x22 => '"',
      0x02 => "'",
      0x6D => "5",  # 'S', '$' も同じパターン
      0x39 => "C",  # '(', '[' も同じ
      0x0F => ")",  # ']' も同じ
      0x04 => ",",
      0x40 => "-",
      0x08 => ".",  # '_' も同じ
      0x5C => "0",  # 'O' も同じ
      0x5B => "2",  # 'Z' も同じ
      0x4F => "3",
      0x66 => "4",
      0x7D => "6",
      0x27 => "7",
      0x7F => "8",
      0x6F => "9",
      0x09 => ":",
      0x48 => "=",
      0x77 => "A",
      0x7C => "b",
      0x5E => "d",
      0x79 => "E",
      0x71 => "F",
      0x3D => "G",
      0x76 => "H",
      0x1E => "J",
      0x38 => "L",
      0x54 => "n",
      0x73 => "P",
      0x67 => "Q",
      0x50 => "r",
      0x78 => "t",
      0x3E => "U",  # 'V' も同じ
      0x6E => "Y",
      0x23 => "^",
    }.freeze

    def display_text
      display_raw.map { |seg| SEG_TO_ASCII[seg] || SEG_TO_HEX[seg] || "?" }.join
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

    # [type, val] ペアを Ruby オブジェクトに変換
    def slot_to_ruby(type, val)
      case type
      when TT_INTEGER then val
      when TT_STRING  then col_string(val - 1)
      when TT_NIL     then nil
      when TT_TRUE    then true
      when TT_FALSE   then false
      else [type, val]
      end
    end

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
