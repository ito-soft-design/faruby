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
require_relative "disasm"
require_relative "array_new_check"

module FaRuby
  class I8080BytecodeHex
    include VmConstants

    Layout = I8080MemoryLayout

    # クラス発見対象のオペコード
    #
    # **`OP_CLASS` だけです。** 定数の読みも `OP_GETCONST` なので、以前は
    # `FOO = 7` の `FOO` がクラスとして登録され、読むとクラス番号が返って
    # いました (PLC 側と同じ不具合。doc/opcodes.md)。
    CLASS_OPCODES = %i[OP_CLASS].freeze

    # 定数が出てくるオペコード
    CONST_OPCODES = %i[OP_GETCONST OP_SETCONST].freeze

    # メソッド呼び出しオペコード (ユーザーメソッド発見用)
    CALL_OPCODES = %i[OP_SEND OP_SSEND].freeze

    # IVAR 参照オペコード
    IVAR_OPCODES = %i[OP_GETIV OP_SETIV].freeze

    # 組み込みメソッド名 → メソッド ID のマッピング
    # vm_send.a80 / vm_block.a80 の dispatch と一致させること
    BUILTIN_METHOD_IDS = {
      "!="    => 1,
      "!"     => 2,
      "%"     => 3,
      "abs"   => 4,
      "times" => 11,
      "loop"    => 27,
      "new"     => Layout::METHOD_NEW,
      "display" => Layout::METHOD_DISPLAY,
      "getkey"  => Layout::METHOD_GETKEY,
      "puts"    => Layout::METHOD_PUTS,
      "setseg"  => Layout::METHOD_SETSEG,
      "rand"    => Layout::METHOD_RAND,
      "length"  => Layout::METHOD_LENGTH,
      "size"    => Layout::METHOD_LENGTH,
      "<<"      => Layout::METHOD_CONCAT,
      "each"    => Layout::METHOD_EACH,
      "push"    => Layout::METHOD_PUSH,
      "any?"    => Layout::METHOD_ANY_P,
      "all?"    => Layout::METHOD_ALL_P,
      "none?"   => Layout::METHOD_NONE_P,
      "[]"      => Layout::METHOD_SLICE,
    }.freeze

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
      place_init_method_id(mem)
      mem
    end

    # Intel HEX 文字列を生成する
    #
    # vm_hex_path が指定されていれば VM コードのレコードも含める。
    # bank_init が事前に拡張 RAM モードに切り替え済みのため、
    # 0x0000-0x7FFF のデータは直接拡張 RAM に書き込まれる。
    # `Array.new(20)` のように大きさが書いてあれば、書き込む前に止める
    #
    # **実行時にも止まります。** ここで見るのは、定数なら ND8080 へ送る前に
    # 分かるからです。**上限は 8 要素** (PLC は 12)。
    def check_array_new_sizes
      ArrayNewSizes.scan(@all_ireps).each do |found|
        next if found[:size] >= 0 && found[:size] <= Layout::COL_MAX_ARRAY_ELEMS

        form = found[:block] ? "Array.new(#{found[:size]}) { }" : "Array.new(#{found[:size]})"
        raise "#{form} は 1 スロットに収まりません " \
              "(i8080 の上限は #{Layout::COL_MAX_ARRAY_ELEMS} 要素)"
      end
    end

    def generate_hex(vm_hex_path: nil)
      check_array_new_sizes
      # VM コードの HEX をメモリイメージに読み込む
      vm_mem = vm_hex_path ? parse_hex_file(vm_hex_path) : {}

      # バイトコード・プール・IREP テーブルのメモリイメージ
      app_mem = build_memory

      # 統合 (app_mem が vm_mem を上書き)
      all_mem = vm_mem.merge(app_mem)

      # HEX レコード生成
      lines = memory_to_hex_records(all_mem)
      lines << ":00000001FF" # EOF
      lines.join("\n") + "\n"
    end

    private

    # --- Intel HEX ファイルをメモリイメージに読み込む ---
    #
    # 戻り値: { addr => byte } のハッシュ
    def parse_hex_file(path)
      mem = {}
      File.readlines(path).each do |line|
        line = line.strip
        next if line.empty? || !line.start_with?(":")

        len  = line[1, 2].to_i(16)
        addr = line[3, 4].to_i(16)
        type = line[7, 2].to_i(16)
        next unless type == 0x00 # データレコードのみ

        len.times do |i|
          mem[addr + i] = line[9 + i * 2, 2].to_i(16)
        end
      end
      mem
    end

    # --- すべての irep をフラット化 (DFS 前順) ---
    def flatten_ireps
      @all_ireps = []
      collect_ireps_dfs(irep)
    end

    def collect_ireps_dfs(irep_node)
      @all_ireps << irep_node
      irep_node.children.each { |child| collect_ireps_dfs(child) }
    end

    # --- DFS 前順でのサブツリーサイズ ---
    #
    # subtree_sizes[i] = irep i のサブツリーに含まれる irep 数 (自身含む)。
    # 逆順に処理すれば子が先に確定する。
    def subtree_sizes
      @subtree_sizes ||= begin
        sizes = Array.new(@all_ireps.size, 1)
        (@all_ireps.size - 1).downto(0) do |idx|
          pos = idx + 1
          @all_ireps[idx].children.size.times do
            sizes[idx] += sizes[pos]
            pos += sizes[pos]
          end
        end
        sizes
      end
    end

    # --- 子 irep の通し番号を求める ---
    #
    # DFS 前順では子が連続しないため、b 個のサブツリーを飛ばして算出する。
    def child_irep_index(parent_idx, child_b)
      pos = parent_idx + 1
      child_b.times { pos += subtree_sizes[pos] }
      pos
    end

    # --- クラス発見 ---
    #
    # OP_CLASS / OP_GETCONST のオペランドからクラス名を集め、
    # 出てきた順に 1 から番号を振る。0 番はトップレベル (main)。
    def class_numbers
      @class_numbers ||= symbol_operands_of(CLASS_OPCODES).each_with_object({}) do |name, acc|
        acc[name] ||= acc.size + 1
      end
    end

    # 利用者の定数の名前 (クラス名を引いた残り)
    # **組み込みクラスの名前は外します** (`Array` / `Hash`)。外さないと
    # 未代入の値スロットになり、`Array.new` が型違いで止まります
    def constant_names
      @constant_names ||=
        (symbol_operands_of(CONST_OPCODES).uniq - class_numbers.keys -
         BUILTIN_CLASSES.keys)
    end

    def symbol_operands_of(opcodes)
      @all_ireps.flat_map { |ir|
        Disassembler.new(ir).disassemble.filter_map do |inst|
          next unless opcodes.include?(inst[:name])

          ir.symbols[inst[:operands][1].to_i]
        end
      }.compact
    end

    # --- irep 番号 => そのクラスの番号 ---
    #
    # OP_CLASS → レジスタ → OP_EXEC で子 irep がクラス本体。
    # OP_METHOD でその中のメソッド本体も同じクラスに属する。
    def class_of_irep
      @class_of_irep ||= begin
        owner = { 0 => Layout::CLASS_MAIN }
        @all_ireps.each_with_index do |ir, idx|
          has_children = !ir.children.empty?
          in_register = {}
          Disassembler.new(ir).disassemble.each do |inst|
            a = inst[:operands][0].to_i
            b = inst[:operands][1].to_i if inst[:operands].size > 1

            case inst[:name]
            when :OP_CLASS, :OP_GETCONST
              # **定数の読みもここへ来ます。** クラスとして登録された名前の
              # ときだけレジスタにクラス番号を覚えます (OP_EXEC が使う)
              name = ir.symbols[b]
              in_register[a] = class_numbers[name] if name && class_numbers.key?(name)
            when :OP_EXEC
              if has_children && in_register[a]
                body = child_irep_index(idx, b)
                owner[body] = in_register[a]
              end
            when :OP_METHOD
              if has_children && owner.key?(idx)
                child = child_irep_index(idx, b)
                owner[child] = owner[idx]
              end
            end
          end
        end
        owner
      end
    end

    # --- クラスごとのインスタンス変数名 => インデックス ---
    def ivar_indexes
      @ivar_indexes ||= begin
        table = {}
        @all_ireps.each_with_index do |ir, idx|
          number = class_of_irep[idx]
          next if number.nil? || number == Layout::CLASS_MAIN

          names = table[number] ||= {}
          Disassembler.new(ir).disassemble.each do |inst|
            next unless IVAR_OPCODES.include?(inst[:name])

            name = ir.symbols[inst[:operands][1].to_i]
            if name && name.start_with?("@") && !name.start_with?("@@")
              raise "インスタンス変数が多すぎます (> #{Layout::MAX_IVARS})" if !names.key?(name) && names.size >= Layout::MAX_IVARS

              names[name] ||= names.size
            end
          end
        end
        table
      end
    end

    # --- ユーザーメソッド名 => メソッド ID ---
    #
    # OP_DEF のシンボルを集めて ID を振る。
    # 組み込みメソッドと重複しないよう 1 から振り直す。
    def user_method_ids
      @user_method_ids ||= begin
        ids = {}
        @all_ireps.each do |ir|
          Disassembler.new(ir).disassemble.each do |inst|
            next unless inst[:name] == :OP_DEF

            name = ir.symbols[inst[:operands][1].to_i]
            ids[name] ||= ids.size + 1 if name
          end

          # SEND/SSEND でユーザーメソッドを呼ぶ場合もID登録
          Disassembler.new(ir).disassemble.each do |inst|
            next unless CALL_OPCODES.include?(inst[:name])

            name = ir.symbols[inst[:operands][1].to_i]
            next unless name
            next if BUILTIN_METHOD_IDS.key?(name)
            next if name.start_with?("$") || name.start_with?("@")

            ids[name] ||= ids.size + 1
          end
        end
        ids
      end
    end

    # "initialize" のメソッド ID (0 = なし)
    def init_method_id
      user_method_ids.fetch("initialize", 0)
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

    # --- 定数プールの配置 (全 irep) ---
    #
    # 各 irep のプールを POOL_BASE に順次配置する。
    # 各エントリはバリュースロット形式 (4 バイト)。
    # 文字列はスロットに TT_STRING + 文字列データのアドレスを置き、
    # 実データ (長さ 1B + ASCII バイト列) はスロット領域の後ろに並べる。
    #
    # @pool_addrs[i] に irep i のプール先頭アドレスを記録する。
    def place_pool(mem)
      @pool_addrs = []

      # 第 1 パス: 全 irep のスロット領域を配置し、文字列データ開始位置を確定
      slot_cursor = Layout::POOL_BASE
      @all_ireps.each do |ir|
        @pool_addrs << slot_cursor
        slot_cursor += ir.pool.size * Layout::SLOT_BYTES
      end
      string_data_addr = slot_cursor

      # 第 2 パス: 各エントリを書き込む
      @all_ireps.each_with_index do |ir, irep_idx|
        ir.pool.each_with_index do |entry, i|
          addr = @pool_addrs[irep_idx] + i * Layout::SLOT_BYTES
          raise "定数プールが大きすぎます" if addr + Layout::SLOT_BYTES > Layout::POOL_BASE + Layout::POOL_SIZE

          case entry.type
          when :int32, :int64
            place_slot_integer(mem, addr, entry.value)
          when :float
            place_slot_integer(mem, addr, entry.value.to_i)
          when :string, :short_string
            str_bytes = entry.value.bytes
            str_len = [str_bytes.size, 255].min

            raise "文字列データが定数プールに収まりません" if string_data_addr + 1 + str_len > Layout::POOL_BASE + Layout::POOL_SIZE

            # スロット: TT_STRING + アドレス
            mem[addr + 0] = TT_STRING
            mem[addr + 1] = 0
            mem[addr + 2] = string_data_addr & 0xFF
            mem[addr + 3] = (string_data_addr >> 8) & 0xFF

            # 文字列データ: 長さ (1B) + ASCII バイト列
            mem[string_data_addr] = str_len
            str_bytes.first(str_len).each_with_index do |b, j|
              mem[string_data_addr + 1 + j] = b
            end

            string_data_addr += 1 + str_len
          else
            place_slot_nil(mem, addr)
          end
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
    # subtree_size はサブツリーに含まれる irep 数 (自身含む)。
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

        # +4,+5: 定数プール先頭 (irep ごとに異なる)
        pool_addr = @pool_addrs[idx]
        mem[addr + Layout::IREP_OFF_POOL] = pool_addr & 0xFF
        mem[addr + Layout::IREP_OFF_POOL + 1] = (pool_addr >> 8) & 0xFF

        # +6: nregs
        mem[addr + Layout::IREP_OFF_NREGS] = ir.nregs

        # +7: subtree_size (DFS 前順でのサブツリーサイズ、自身含む)
        mem[addr + Layout::IREP_OFF_SUBTREE_SIZE] = subtree_sizes[idx]

        # +8,+9: シンボルテーブル先頭アドレス
        sym = @sym_addrs[idx]
        mem[addr + Layout::IREP_OFF_SYM_TABLE] = sym & 0xFF
        mem[addr + Layout::IREP_OFF_SYM_TABLE + 1] = (sym >> 8) & 0xFF
      end
    end

    # --- シンボルテーブルの配置 (全 irep) ---
    #
    # 各 irep のシンボルを SYM_TABLE_BASE に順次配置する。
    # シンボルの種別に応じて 2 バイトエントリのエンコードを変える:
    #
    #   D=0x00, E=1-31  : 組み込みメソッド
    #   D=0x01, E=id    : ユーザー定義メソッド
    #   D=0x02, E=num   : クラス名
    #   D=0x03, E=idx   : インスタンス変数
    #   D>=0x80, E=lo   : グローバル変数アドレス
    #
    # @sym_addrs[i] に irep i のシンボルテーブル先頭アドレスを記録する。
    def place_all_symbol_tables(mem)
      sym_cursor = Layout::SYM_TABLE_BASE
      @sym_addrs = []
      globals_map = {}   # シンボル名 => スロットアドレス (重複排除)
      globals_count = 0

      @all_ireps.each_with_index do |ir, irep_idx|
        @sym_addrs << sym_cursor
        owner = class_of_irep[irep_idx]

        ir.symbols.each_with_index do |sym, idx|
          tbl_addr = sym_cursor + idx * 2

          if sym.nil?
            mem[tbl_addr]     = 0
            mem[tbl_addr + 1] = 0
          elsif sym.start_with?("$")
            # グローバル変数 ($foo) — アドレスをそのまま書く
            slot_addr = resolve_global(mem, sym, globals_map, globals_count)
            globals_count += 1 unless globals_map.key?(sym) # already incremented in resolve_global
            globals_count = globals_map.size

            mem[tbl_addr]     = slot_addr & 0xFF
            mem[tbl_addr + 1] = (slot_addr >> 8) & 0xFF
          elsif sym.start_with?("@@")
            # **クラス変数はクラスごとに 1 枠。** 名前ではなく「どのクラスの
            # `@@n` か」で場所が決まるので、クラス番号を付けた鍵で取ります。
            # 命令は OP_GETGV / OP_SETGV の枝に落ちるだけです
            slot_addr = resolve_global(mem, "#{owner}:#{sym}", globals_map, globals_count)
            globals_count = globals_map.size

            mem[tbl_addr]     = slot_addr & 0xFF
            mem[tbl_addr + 1] = (slot_addr >> 8) & 0xFF
          elsif sym.start_with?("@")
            # @ シンボル: クラスのメソッド内 → IVAR、それ以外 → グローバル
            ivar_idx = ivar_index(sym, owner)
            if ivar_idx
              mem[tbl_addr]     = ivar_idx
              mem[tbl_addr + 1] = Layout::SYM_KIND_IVAR
            else
              # トップレベルの @ はグローバルと同じ扱い
              slot_addr = resolve_global(mem, sym, globals_map, globals_count)
              globals_count = globals_map.size

              mem[tbl_addr]     = slot_addr & 0xFF
              mem[tbl_addr + 1] = (slot_addr >> 8) & 0xFF
            end
          elsif constant_names.include?(sym)
            # 利用者の定数。**グローバルと同じ値スロット**
            slot_addr = resolve_global(mem, sym, globals_map, globals_count)
            globals_count = globals_map.size

            mem[tbl_addr]     = slot_addr & 0xFF
            mem[tbl_addr + 1] = (slot_addr >> 8) & 0xFF
          elsif BUILTIN_CLASSES.key?(sym)
            # 組み込みクラス (`Array` / `Hash`)
            mem[tbl_addr]     = BUILTIN_CLASSES[sym]
            mem[tbl_addr + 1] = Layout::SYM_KIND_BUILTIN_CLASS
          elsif class_numbers.key?(sym)
            # クラス名
            mem[tbl_addr]     = class_numbers[sym]
            mem[tbl_addr + 1] = Layout::SYM_KIND_CLASS
          elsif BUILTIN_METHOD_IDS.key?(sym)
            # 組み込みメソッド
            mid = BUILTIN_METHOD_IDS[sym]
            mem[tbl_addr]     = mid & 0xFF
            mem[tbl_addr + 1] = 0
          elsif user_method_ids.key?(sym)
            # ユーザー定義メソッド
            mid = user_method_ids[sym]
            mem[tbl_addr]     = mid & 0xFF
            mem[tbl_addr + 1] = Layout::SYM_KIND_USER_METHOD
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

    # グローバル変数のスロットアドレスを取得 (重複排除)
    def resolve_global(mem, sym, globals_map, _count)
      unless globals_map.key?(sym)
        raise "グローバル変数が多すぎます (> #{Layout::MAX_GLOBALS})" if globals_map.size >= Layout::MAX_GLOBALS

        slot_addr = Layout::GLOBALS_BASE + globals_map.size * Layout::SLOT_BYTES
        globals_map[sym] = slot_addr
        place_slot_nil(mem, slot_addr)
      end
      globals_map[sym]
    end

    # インスタンス変数のインデックスを返す (クラス外なら nil)
    def ivar_index(sym, owner)
      return nil if owner.nil? || owner == Layout::CLASS_MAIN

      indexes = ivar_indexes[owner]
      indexes&.[](sym)
    end

    # --- INIT_METHOD_ID を格納する ---
    #
    # VM_STATE_BASE 内ではなく INIT_METHOD_ID_STORE に書く。
    # vm_start が VM 状態をゼロクリアした後にここから読み出す。
    def place_init_method_id(mem)
      mem[Layout::INIT_METHOD_ID_STORE] = init_method_id & 0xFF
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
