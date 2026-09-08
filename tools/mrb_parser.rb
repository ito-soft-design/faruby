# frozen_string_literal: true

# RITE バイナリ (.mrb) パーサー
# mruby の mrbc が出力する RITE 形式のバイトコードを解析し、
# IREP (命令列、定数プール、シンボル) を抽出します。

require_relative "opcode_table"

module FaRuby
  # RITE バイナリヘッダー (20 bytes)
  class RiteHeader
    MAGIC = "RITE"
    HEADER_SIZE = 20

    attr_reader :binary_ident, :binary_version, :binary_size,
                :compiler_name, :compiler_version

    def initialize(data)
      raise "Data too short for RITE header" if data.bytesize < HEADER_SIZE

      @binary_ident     = data[0, 4]
      @binary_version   = data[4, 4]
      @binary_size      = data[8, 4].unpack1("N")   # big-endian uint32
      @compiler_name    = data[12, 4]
      @compiler_version = data[16, 4]

      raise "Invalid RITE magic: #{@binary_ident.inspect}" unless @binary_ident == MAGIC
    end

    def to_s
      "RITE #{@binary_version} size=#{@binary_size} compiler=#{@compiler_name}#{@compiler_version}"
    end
  end

  # IREP 内の定数プールエントリ
  class PoolEntry
    TYPES = {
      0 => :string,
      1 => :int32,
      2 => :short_string,
      3 => :int64,
      5 => :float,
      7 => :bigint,
    }.freeze

    attr_reader :type, :value

    def initialize(type, value)
      @type = type
      @value = value
    end

    def to_s
      "#{@type}:#{@value}"
    end
  end

  # IREP レコード
  class Irep
    attr_reader :nlocals, :nregs, :rlen, :clen, :ilen,
                :instructions, :pool, :symbols, :children

    def initialize
      @nlocals = 0
      @nregs = 0
      @rlen = 0
      @clen = 0
      @ilen = 0
      @instructions = []  # raw bytes
      @pool = []
      @symbols = []
      @children = []
    end

    attr_writer :nlocals, :nregs, :rlen, :clen, :ilen, :instructions

    def add_pool_entry(entry)
      @pool << entry
    end

    def add_symbol(sym)
      @symbols << sym
    end

    def add_child(child)
      @children << child
    end

    def to_s
      "IREP nlocals=#{@nlocals} nregs=#{@nregs} rlen=#{@rlen} clen=#{@clen} " \
        "ilen=#{@ilen} pool=#{@pool.size} syms=#{@symbols.size}"
    end
  end

  # メインパーサー
  class MrbParser
    attr_reader :header, :irep

    def initialize(data)
      @data = data.b  # バイナリモードで扱う
      @pos = 0
    end

    def parse
      @header = parse_header
      parse_sections
      rewrite_index_sends(@irep) if @irep
      self
    end

    private

    # 添字への複合代入を専用命令に置き換える
    #
    # **`x[i] op= v` は `[]` と `[]=` のメソッド呼び出しになります。** 素の
    # `x[i]` と `x[i] = v` が OP_GETIDX / OP_SETIDX なのに、複合代入だけ
    # メソッド呼び出しになるのは mruby の出し方です。そのままでは
    # `$DM[a] |= 1 << 3` も `a[0] += 1` も未対応のメソッドで止まります。
    #
    # **OP_GETIDX / OP_SETIDX はレジスタの並びまで同じ**なので、ここで
    # 置き換えます。OP_SEND は 4 バイト、専用命令は 2 バイトなので、
    # 残りは OP_NOP で埋めて**長さを変えません** (飛び先がずれるため)。
    #
    #   OP_SEND a, [], 1   →  OP_GETIDX a + OP_NOP × 2
    #   OP_SEND a, []=, 2  →  OP_SETIDX a + OP_NOP × 2
    #
    # 引数 2 個の `[]` ($DML[100, 3] の連続読み) はそのままにします。
    # あちらは連続した値を配列にするもので、意味が違います。
    #
    # VM は 1 行も増えません。**組み込みメソッドを増やすと OP_SEND の中で
    # デバイスアクセスをもう一式持つことになり**、いちばん大きいスクリプトが
    # KV Studio の上限に近づきます。
    def rewrite_index_sends(irep)
      bytes = irep.instructions.b.bytes
      pc = 0
      while pc < bytes.size
        info = OpcodeTable::MRUBY_OPCODES[bytes[pc]]
        break unless info   # 知らない命令。長さが分からないのでここで止める

        # OP_SEND は a=レシーバ、b=シンボル、c=引数の数
        if bytes[pc] == OP_SEND &&
           (target = index_opcode_for(irep.symbols[bytes[pc + 2]], bytes[pc + 3]))
          bytes[pc]     = target       # a (pc + 1) はそのまま使える
          bytes[pc + 2] = OP_NOP
          bytes[pc + 3] = OP_NOP
        end

        pc += 1 + OpcodeTable::FORMAT_SIZES.fetch(info[1], 0)
      end
      irep.instructions = bytes.pack("C*")
      irep.children.each { |child| rewrite_index_sends(child) }
    end

    OP_NOP    = 0x00
    OP_GETIDX = 0x23
    OP_SETIDX = 0x24
    OP_SEND   = 0x2F

    def index_opcode_for(symbol, argc)
      return OP_GETIDX if symbol == "[]" && argc == 1
      return OP_SETIDX if symbol == "[]=" && argc == 2

      nil
    end

    def parse_header
      header = RiteHeader.new(@data[@pos, RiteHeader::HEADER_SIZE])
      @pos += RiteHeader::HEADER_SIZE
      header
    end

    def parse_sections
      while @pos < @data.bytesize
        section_ident = @data[@pos, 4]
        section_size = @data[@pos + 4, 4].unpack1("N")

        case section_ident
        when "IREP"
          parse_irep_section(section_size)
        when "END\x00"
          break
        else
          # 未知のセクション (DBG, LVAR 等) はスキップ
          @pos += section_size
        end
      end
    end

    def parse_irep_section(section_size)
      section_start = @pos
      @pos += 8  # section_ident (4) + section_size (4)

      # IREP セクションヘッダーの rite_version (4 bytes)
      _rite_version = @data[@pos, 4]
      @pos += 4

      # トップレベル IREP を再帰的にパース
      @irep = parse_irep_record

      # セクション末尾まで移動
      @pos = section_start + section_size
    end

    def parse_irep_record
      irep = Irep.new

      # record_size (4 bytes)
      _record_size = read_uint32

      # nlocals (2), nregs (2), rlen (2), clen (2)
      irep.nlocals = read_uint16
      irep.nregs   = read_uint16
      irep.rlen    = read_uint16
      irep.clen    = read_uint16

      # ilen (4) - 命令バイト数
      irep.ilen = read_uint32

      # 命令バイト列
      irep.instructions = read_bytes(irep.ilen)

      # catch handler table (clen * 13 bytes)
      @pos += irep.clen * 13

      # 定数プール
      plen = read_uint16
      plen.times do
        irep.add_pool_entry(parse_pool_entry)
      end

      # シンボルテーブル
      slen = read_uint16
      slen.times do
        irep.add_symbol(parse_symbol)
      end

      # 子 IREP を再帰的にパース
      irep.rlen.times do
        irep.add_child(parse_irep_record)
      end

      irep
    end

    def parse_pool_entry
      type_byte = read_uint8

      case type_byte
      when 0  # IREP_TT_STR
        len = read_uint16
        value = read_bytes(len)
        @pos += 1  # null terminator
        PoolEntry.new(:string, value)
      when 1  # IREP_TT_INT32
        value = @data[@pos, 4].unpack1("N")
        # 符号付き変換
        value -= 0x1_0000_0000 if value >= 0x8000_0000
        @pos += 4
        PoolEntry.new(:int32, value)
      when 2  # IREP_TT_SSTR (short string)
        len = read_uint16
        value = read_bytes(len)
        @pos += 1  # null terminator
        PoolEntry.new(:short_string, value)
      when 3  # IREP_TT_INT64
        hi = @data[@pos, 4].unpack1("N")
        lo = @data[@pos + 4, 4].unpack1("N")
        value = (hi << 32) | lo
        value -= (1 << 64) if value >= (1 << 63)
        @pos += 8
        PoolEntry.new(:int64, value)
      when 5  # IREP_TT_FLOAT
        # 実数だけはリトルエンディアン。整数や長さは RITE 形式に従って
        # ビッグエンディアンだが、mruby の dump.c は double をネイティブの
        # バイト順のまま書き出すため (x86 でビルドした mrbc の出力を前提)。
        value = @data[@pos, 8].unpack1("E")
        @pos += 8
        PoolEntry.new(:float, value)
      when 7  # IREP_TT_BIGINT
        len = read_uint8
        sign = read_uint8
        digits = read_bytes(len)
        PoolEntry.new(:bigint, { sign: sign, digits: digits })
      else
        raise "Unknown pool type: #{type_byte} at pos #{@pos}"
      end
    end

    def parse_symbol
      len = read_uint16
      if len == 0xFFFF
        nil  # 空シンボル
      else
        sym = read_bytes(len)
        @pos += 1  # null terminator
        sym
      end
    end

    # バイナリ読み取りヘルパー
    def read_uint8
      val = @data.getbyte(@pos)
      @pos += 1
      val
    end

    def read_uint16
      val = @data[@pos, 2].unpack1("n")  # big-endian uint16
      @pos += 2
      val
    end

    def read_uint32
      val = @data[@pos, 4].unpack1("N")  # big-endian uint32
      @pos += 4
      val
    end

    def read_bytes(len)
      val = @data[@pos, len]
      @pos += len
      val
    end
  end
end

# コマンドラインから実行した場合
if __FILE__ == $0
  if ARGV.empty?
    puts "Usage: ruby mrb_parser.rb <file.mrb>"
    exit 1
  end

  data = File.binread(ARGV[0])
  parser = FaRuby::MrbParser.new(data).parse

  puts "=== RITE Header ==="
  puts parser.header

  puts "\n=== Top-level IREP ==="
  puts parser.irep

  puts "\n=== Instructions (hex) ==="
  parser.irep.instructions.each_byte.each_with_index do |b, i|
    print format("%02x ", b)
    puts if (i + 1) % 16 == 0
  end
  puts

  unless parser.irep.pool.empty?
    puts "\n=== Pool ==="
    parser.irep.pool.each_with_index { |e, i| puts "  [#{i}] #{e}" }
  end

  unless parser.irep.symbols.empty?
    puts "\n=== Symbols ==="
    parser.irep.symbols.each_with_index { |s, i| puts "  [#{i}] #{s || '(nil)'}" }
  end
end
