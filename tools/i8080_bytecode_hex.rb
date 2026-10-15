# frozen_string_literal: true

# i8080 用バイトコード → Intel HEX 変換
#
# MrbParser で .mrb を読み、i8080 メモリマップに沿って配置し、
# VM コードの HEX ファイルとマージして 1 本の Intel HEX を出力します。
#
# 使い方:
#   ruby tools/i8080_bytecode_hex.rb program.mrb [vm_main.hex] > combined.hex
#
# vm_main.hex を省略すると、バイトコード・定数プール・IREP テーブルだけを出力。

require_relative "mrb_parser"
require_relative "vm_constants"
require_relative "i8080_memory_layout"

module FaRuby
  class I8080BytecodeHex
    include VmConstants

    Layout = I8080MemoryLayout

    def initialize(mrb_data)
      @parser = MrbParser.new(mrb_data).parse
      @irep = @parser.irep
    end

    attr_reader :irep

    # メモリイメージを構築する (アドレス => バイト のハッシュ)
    def build_memory
      mem = {}
      place_bytecode(mem)
      place_pool(mem)
      place_irep_table(mem)
      place_symbol_table(mem)
      mem
    end

    # Intel HEX 文字列を生成する
    #
    # vm_hex_path が指定されていれば VM コードのレコードも含める。
    def generate_hex(vm_hex_path: nil)
      lines = []

      # VM コードの HEX を取り込む (EOF レコードを除く)
      if vm_hex_path
        File.readlines(vm_hex_path).each do |line|
          line = line.strip
          next if line.empty?
          next if line == ":00000001FF" # EOF レコードは後で追加
          next if line.start_with?(":00") && line.include?("01") && line.length < 15

          lines << line
        end
      end

      # バイトコード・プール・IREP テーブルの HEX レコード
      mem = build_memory
      lines.concat(memory_to_hex_records(mem))

      # EOF レコード
      lines << ":00000001FF"
      lines.join("\n") + "\n"
    end

    private

    # --- バイトコードの配置 ---
    def place_bytecode(mem)
      bytes = irep.instructions
      raise "バイトコードが大きすぎます (#{bytes.size} > #{Layout::BYTECODE_SIZE})" if bytes.size > Layout::BYTECODE_SIZE

      bytes = bytes.bytes if bytes.is_a?(String)
      bytes.each_with_index do |byte, i|
        mem[Layout::BYTECODE_BASE + i] = byte
      end
    end

    # --- 定数プールの配置 ---
    #
    # 各エントリをバリュースロット形式 (8 バイト) に変換して配置する。
    # Phase 1 は整数のみ対応。
    def place_pool(mem)
      irep.pool.each_with_index do |entry, i|
        addr = Layout::POOL_BASE + i * Layout::SLOT_BYTES
        raise "定数プールが大きすぎます" if addr + Layout::SLOT_BYTES > Layout::POOL_BASE + Layout::POOL_SIZE

        case entry.type
        when :int32, :int64
          place_slot_integer(mem, addr, entry.value)
        when :float
          # Phase 1 では未対応だが、エラーにはしない
          place_slot_integer(mem, addr, entry.value.to_i)
        when :string, :short_string
          # Phase 1 では未対応
          place_slot_nil(mem, addr)
        else
          place_slot_nil(mem, addr)
        end
      end
    end

    # 整数をバリュースロットに書く (16 ビット)
    def place_slot_integer(mem, addr, value)
      raise "値が 16 ビット範囲外: #{value}" if value < -32768 || value > 32767

      # 型タグ
      mem[addr + 0] = TT_INTEGER
      mem[addr + 1] = 0   # 予約
      # 値 (リトルエンディアン 16 ビット)
      val = value & 0xFFFF
      mem[addr + 2] = val & 0xFF
      mem[addr + 3] = (val >> 8) & 0xFF
    end

    # nil をバリュースロットに書く
    def place_slot_nil(mem, addr)
      Layout::SLOT_BYTES.times { |i| mem[addr + i] = 0 }
      mem[addr] = TT_NIL
    end

    # --- IREP テーブルの配置 ---
    #
    # Phase 1 ではトップレベル irep (index 0) だけ。
    def place_irep_table(mem)
      addr = Layout::IREP_TABLE_BASE

      # バイトコード先頭アドレス (2B, リトルエンディアン)
      bc_addr = Layout::BYTECODE_BASE
      mem[addr + Layout::IREP_OFF_BYTECODE] = bc_addr & 0xFF
      mem[addr + Layout::IREP_OFF_BYTECODE + 1] = (bc_addr >> 8) & 0xFF

      # バイトコード長 (2B)
      bc_len = irep.ilen
      mem[addr + Layout::IREP_OFF_BYTECODE_LEN] = bc_len & 0xFF
      mem[addr + Layout::IREP_OFF_BYTECODE_LEN + 1] = (bc_len >> 8) & 0xFF

      # 定数プール先頭アドレス (2B)
      pool_addr = Layout::POOL_BASE
      mem[addr + Layout::IREP_OFF_POOL] = pool_addr & 0xFF
      mem[addr + Layout::IREP_OFF_POOL + 1] = (pool_addr >> 8) & 0xFF

      # nregs (1B)
      mem[addr + Layout::IREP_OFF_NREGS] = irep.nregs

      # 予備 (1B)
      mem[addr + Layout::IREP_OFF_NREGS + 1] = 0
    end

    # 組み込みメソッド名 → メソッド ID のマッピング
    # vm_send.a80 の send_dispatch と一致させること
    METHOD_IDS = {
      "!=" => 1,
      "!"  => 2,
      "%"  => 3,
      "abs" => 4,
    }.freeze

    # --- シンボルテーブルの配置 ---
    #
    # irep のシンボルテーブルを走査し、各シンボルに対応する値を書く:
    #   - $ または @ で始まるシンボル → グローバルスロットのアドレス (>= 0xB000)
    #   - METHOD_IDS に含まれるシンボル → メソッド ID (0x0001-0x00FF)
    #   - それ以外 → 0x0000 (未対応マーカー)
    def place_symbol_table(mem)
      return if irep.symbols.empty?

      raise "シンボルが多すぎます (#{irep.symbols.size} > #{Layout::MAX_SYMBOLS})" if irep.symbols.size > Layout::MAX_SYMBOLS

      globals_count = 0

      irep.symbols.each_with_index do |sym, idx|
        tbl_addr = Layout::SYM_TABLE_BASE + idx * 2

        if sym && (sym.start_with?("$") || sym.start_with?("@"))
          # グローバル変数 / インスタンス変数 — スロットを割り当てる
          raise "グローバル変数が多すぎます (> #{Layout::MAX_GLOBALS})" if globals_count >= Layout::MAX_GLOBALS

          slot_addr = Layout::GLOBALS_BASE + globals_count * Layout::SLOT_BYTES
          globals_count += 1

          # シンボルテーブルにスロットアドレスを書く
          mem[tbl_addr]     = slot_addr & 0xFF
          mem[tbl_addr + 1] = (slot_addr >> 8) & 0xFF

          # グローバルスロットを nil で初期化
          place_slot_nil(mem, slot_addr)
        elsif sym && METHOD_IDS.key?(sym)
          # 組み込みメソッド — メソッド ID を書く
          mid = METHOD_IDS[sym]
          mem[tbl_addr]     = mid & 0xFF
          mem[tbl_addr + 1] = 0   # 上位バイト = 0 → メソッド ID
        else
          # 未対応 — アドレス 0
          mem[tbl_addr]     = 0
          mem[tbl_addr + 1] = 0
        end
      end
    end

    # --- Intel HEX レコード生成 ---

    # メモリイメージを 16 バイト単位の HEX レコードに変換する
    def memory_to_hex_records(mem)
      return [] if mem.empty?

      records = []
      # アドレス順にソートして連続領域ごとにまとめる
      sorted_addrs = mem.keys.sort
      chunk_start = sorted_addrs.first
      chunk = []

      sorted_addrs.each do |addr|
        if chunk.empty? || addr == chunk_start + chunk.size
          chunk << mem[addr]
        else
          records.concat(chunk_to_records(chunk_start, chunk))
          chunk_start = addr
          chunk = [mem[addr]]
        end
      end
      records.concat(chunk_to_records(chunk_start, chunk)) unless chunk.empty?
      records
    end

    # 連続バイト列を 16 バイト単位のレコードに分割する
    def chunk_to_records(base_addr, bytes)
      records = []
      bytes.each_slice(16).with_index do |slice, i|
        addr = base_addr + i * 16
        records << format_hex_record(addr, slice)
      end
      records
    end

    # 1 レコードのフォーマット
    def format_hex_record(address, data)
      len = data.size
      type = 0x00 # データレコード
      sum = len + ((address >> 8) & 0xFF) + (address & 0xFF) + type
      hex_data = data.map { |b| format("%02X", b) }.join
      sum += data.sum
      checksum = (-sum) & 0xFF
      format(":%02X%04X%02X%s%02X", len, address, type, hex_data, checksum)
    end
  end
end

# 直接実行
if $PROGRAM_NAME == __FILE__
  if ARGV.empty?
    warn "使い方: ruby #{$PROGRAM_NAME} program.mrb [vm_main.hex]"
    exit 1
  end

  mrb_path = ARGV[0]
  vm_hex_path = ARGV[1]

  mrb_data = File.binread(mrb_path)
  hex_gen = FaRuby::I8080BytecodeHex.new(mrb_data)
  puts hex_gen.generate_hex(vm_hex_path: vm_hex_path)
end
