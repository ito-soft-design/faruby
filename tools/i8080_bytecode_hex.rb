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
      flatten_ireps
    end

    attr_reader :irep, :all_ireps

    # メモリイメージを構築する (アドレス => バイト のハッシュ)
    def build_memory
      mem = {}
      place_all_bytecodes(mem)
      place_pool(mem)
      place_all_symbol_tables(mem)
      place_all_irep_entries(mem)
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

    # --- すべての irep をフラット化 (DFS 前順) ---
    def flatten_ireps
      @all_ireps = []
      collect_ireps_dfs(irep)
    end

    def collect_ireps_dfs(irep_node)
      @all_ireps << irep_node
      irep_node.children.each { |child| collect_ireps_dfs(child) }
    end

    # --- バイトコードの配置 (全 irep) ---
    #
    # 各 irep のバイトコードを BYTECODE_BASE に順次配置する。
    # @bc_addrs[i] に irep i の絶対先頭アドレスを記録する。
    def place_all_bytecodes(mem)
      offset = 0
      @bc_addrs = []

      @all_ireps.each do |ir|
        @bc_addrs << (Layout::BYTECODE_BASE + offset)
        bytes = ir.instructions
        bytes = bytes.bytes if bytes.is_a?(String)
        bytes.each_with_index do |byte, i|
          mem[Layout::BYTECODE_BASE + offset + i] = byte
        end
        offset += ir.ilen
      end

      raise "バイトコードが大きすぎます (#{offset} > #{Layout::BYTECODE_SIZE})" if offset > Layout::BYTECODE_SIZE
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

    # --- IREP テーブルの配置 (全 irep) ---
    #
    # DFS 前順で番号付けした全 irep のエントリを書く。
    # first_child は DFS 前順の性質から index + 1 (子がある場合)。
    def place_all_irep_entries(mem)
      @all_ireps.each_with_index do |ir, idx|
        addr = Layout::IREP_TABLE_BASE + idx * Layout::IREP_ENTRY_BYTES

        # +0,+1: バイトコード先頭アドレス
        bc = @bc_addrs[idx]
        mem[addr + Layout::IREP_OFF_BYTECODE] = bc & 0xFF
        mem[addr + Layout::IREP_OFF_BYTECODE + 1] = (bc >> 8) & 0xFF

        # +2,+3: バイトコード長
        mem[addr + Layout::IREP_OFF_BYTECODE_LEN] = ir.ilen & 0xFF
        mem[addr + Layout::IREP_OFF_BYTECODE_LEN + 1] = (ir.ilen >> 8) & 0xFF

        # +4,+5: 定数プール先頭 (全 irep で共有)
        pool_addr = Layout::POOL_BASE
        mem[addr + Layout::IREP_OFF_POOL] = pool_addr & 0xFF
        mem[addr + Layout::IREP_OFF_POOL + 1] = (pool_addr >> 8) & 0xFF

        # +6: nregs
        mem[addr + Layout::IREP_OFF_NREGS] = ir.nregs

        # +7: first_child (DFS 前順 → 子があれば index + 1)
        first_child = ir.children.empty? ? 0xFF : idx + 1
        mem[addr + Layout::IREP_OFF_FIRST_CHILD] = first_child

        # +8,+9: シンボルテーブル先頭アドレス
        sym = @sym_addrs[idx]
        mem[addr + Layout::IREP_OFF_SYM_TABLE] = sym & 0xFF
        mem[addr + Layout::IREP_OFF_SYM_TABLE + 1] = (sym >> 8) & 0xFF
      end
    end

    # 組み込みメソッド名 → メソッド ID のマッピング
    # vm_send.a80 / vm_block.a80 の dispatch と一致させること
    METHOD_IDS = {
      "!="    => 1,
      "!"     => 2,
      "%"     => 3,
      "abs"   => 4,
      "times" => 11,
      "loop"  => 27,
    }.freeze

    # --- シンボルテーブルの配置 (全 irep) ---
    #
    # 各 irep のシンボルを SYM_TABLE_BASE に順次配置する。
    # 同名のグローバル/インスタンス変数は同じスロットを共有する。
    # @sym_addrs[i] に irep i のシンボルテーブル先頭アドレスを記録する。
    def place_all_symbol_tables(mem)
      sym_cursor = Layout::SYM_TABLE_BASE
      @sym_addrs = []
      globals_map = {}   # シンボル名 => スロットアドレス (重複排除)
      globals_count = 0

      @all_ireps.each do |ir|
        @sym_addrs << sym_cursor

        ir.symbols.each_with_index do |sym, idx|
          tbl_addr = sym_cursor + idx * 2

          if sym && (sym.start_with?("$") || sym.start_with?("@"))
            # グローバル/インスタンス変数 — 同名なら同じスロットを再利用
            if globals_map.key?(sym)
              slot_addr = globals_map[sym]
            else
              raise "グローバル変数が多すぎます (> #{Layout::MAX_GLOBALS})" if globals_count >= Layout::MAX_GLOBALS

              slot_addr = Layout::GLOBALS_BASE + globals_count * Layout::SLOT_BYTES
              globals_map[sym] = slot_addr
              globals_count += 1
              place_slot_nil(mem, slot_addr)
            end

            mem[tbl_addr]     = slot_addr & 0xFF
            mem[tbl_addr + 1] = (slot_addr >> 8) & 0xFF
          elsif sym && METHOD_IDS.key?(sym)
            mid = METHOD_IDS[sym]
            mem[tbl_addr]     = mid & 0xFF
            mem[tbl_addr + 1] = 0
          else
            mem[tbl_addr]     = 0
            mem[tbl_addr + 1] = 0
          end
        end

        sym_cursor += ir.symbols.size * 2
      end

      total = sym_cursor - Layout::SYM_TABLE_BASE
      raise "シンボルテーブルが大きすぎます (#{total} > #{Layout::SYM_TABLE_SIZE})" if total > Layout::SYM_TABLE_SIZE
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
