# frozen_string_literal: true

# mruby バイトコード逆アセンブラ
# IREP の命令バイト列を人間が読める形式にデコードします。

require_relative "mrb_parser"

module RubyOnPlc
  class Disassembler
    # オペコード定義: [名前, 形式]
    # mruby 3.x (ops.h に基づく)
    OPCODES = {
      0x00 => [:OP_NOP,       :Z],
      0x01 => [:OP_MOVE,      :BB],
      0x02 => [:OP_LOADL,     :BB],
      0x03 => [:OP_LOADI8,    :BB],
      0x04 => [:OP_LOADINEG,  :BB],
      0x05 => [:OP_LOADI__1,  :B],
      0x06 => [:OP_LOADI_0,   :B],
      0x07 => [:OP_LOADI_1,   :B],
      0x08 => [:OP_LOADI_2,   :B],
      0x09 => [:OP_LOADI_3,   :B],
      0x0A => [:OP_LOADI_4,   :B],
      0x0B => [:OP_LOADI_5,   :B],
      0x0C => [:OP_LOADI_6,   :B],
      0x0D => [:OP_LOADI_7,   :B],
      0x0E => [:OP_LOADI16,   :BS],
      0x0F => [:OP_LOADI32,   :BSS],
      0x10 => [:OP_LOADSYM,   :BB],
      0x11 => [:OP_LOADNIL,   :B],
      0x12 => [:OP_LOADSELF,  :B],
      0x13 => [:OP_LOADTRUE,  :B],
      0x14 => [:OP_LOADFALSE, :B],
      0x15 => [:OP_GETGV,     :BB],
      0x16 => [:OP_SETGV,     :BB],
      0x17 => [:OP_GETSV,     :BB],
      0x18 => [:OP_SETSV,     :BB],
      0x19 => [:OP_GETIV,     :BB],
      0x1A => [:OP_SETIV,     :BB],
      0x1B => [:OP_GETCV,     :BB],
      0x1C => [:OP_SETCV,     :BB],
      0x1D => [:OP_GETCONST,  :BB],
      0x1E => [:OP_SETCONST,  :BB],
      0x1F => [:OP_GETMCNST,  :BB],
      0x20 => [:OP_SETMCNST,  :BB],
      0x21 => [:OP_GETUPVAR,  :BBB],
      0x22 => [:OP_SETUPVAR,  :BBB],
      0x23 => [:OP_GETIDX,    :B],
      0x24 => [:OP_SETIDX,    :B],
      0x25 => [:OP_JMP,       :S],
      0x26 => [:OP_JMPIF,     :BS],
      0x27 => [:OP_JMPNOT,    :BS],
      0x28 => [:OP_JMPNIL,    :BS],
      0x29 => [:OP_JMPUW,     :S],
      0x2A => [:OP_EXCEPT,    :B],
      0x2B => [:OP_RESCUE,    :BB],
      0x2C => [:OP_RAISEIF,   :B],
      0x2D => [:OP_SSEND,     :BBB],
      0x2E => [:OP_SSENDB,    :BBB],
      0x2F => [:OP_SEND,      :BBB],
      0x30 => [:OP_SENDB,     :BBB],
      0x31 => [:OP_CALL,      :Z],
      0x32 => [:OP_SUPER,     :BB],
      0x33 => [:OP_ARGARY,    :BS],
      0x34 => [:OP_ENTER,     :W],
      0x35 => [:OP_KEY_P,     :BBB],
      0x36 => [:OP_KEYEND,    :Z],
      0x37 => [:OP_KARG,      :BB],
      0x38 => [:OP_RETURN,    :B],
      0x39 => [:OP_RETURN_BLK, :B],
      0x3A => [:OP_BREAK,     :B],
      0x3B => [:OP_BLKPUSH,   :BS],
      0x3C => [:OP_ADD,       :B],
      0x3D => [:OP_ADDI,      :BB],
      0x3E => [:OP_SUB,       :B],
      0x3F => [:OP_SUBI,      :BB],
      0x40 => [:OP_MUL,       :B],
      0x41 => [:OP_DIV,       :B],
      0x42 => [:OP_EQ,        :B],
      0x43 => [:OP_LT,        :B],
      0x44 => [:OP_LE,        :B],
      0x45 => [:OP_GT,        :B],
      0x46 => [:OP_GE,        :B],
      0x47 => [:OP_ARRAY,     :BB],
      0x48 => [:OP_ARRAY2,    :BBB],
      0x49 => [:OP_ARYCAT,    :B],
      0x4A => [:OP_ARYPUSH,   :BB],
      0x4B => [:OP_ARYSPLAT,  :B],
      0x4C => [:OP_AREF,      :BBB],
      0x4D => [:OP_ASET,      :BBB],
      0x4E => [:OP_APOST,     :BBB],
      0x4F => [:OP_INTERN,    :B],
      0x50 => [:OP_SYMBOL,    :BB],
      0x51 => [:OP_STRING,    :BB],
      0x52 => [:OP_STRCAT,    :B],
      0x53 => [:OP_HASH,      :BB],
      0x54 => [:OP_HASHADD,   :BB],
      0x55 => [:OP_HASHCAT,   :B],
      0x56 => [:OP_LAMBDA,    :BB],
      0x57 => [:OP_BLOCK,     :BB],
      0x58 => [:OP_METHOD,    :BB],
      0x59 => [:OP_RANGE_INC, :B],
      0x5A => [:OP_RANGE_EXC, :B],
      0x5B => [:OP_OCLASS,    :B],
      0x5C => [:OP_CLASS,     :BB],
      0x5D => [:OP_MODULE,    :BB],
      0x5E => [:OP_EXEC,      :BB],
      0x5F => [:OP_DEF,       :BB],
      0x60 => [:OP_ALIAS,     :BB],
      0x61 => [:OP_UNDEF,     :BB],
      0x62 => [:OP_SCLASS,    :B],
      0x63 => [:OP_TCLASS,    :B],
      0x64 => [:OP_DEBUG,     :BBB],
      0x65 => [:OP_ERR,       :B],
      0x66 => [:OP_EXT1,      :Z],
      0x67 => [:OP_EXT2,      :Z],
      0x68 => [:OP_EXT3,      :Z],
      0x69 => [:OP_STOP,      :Z],
    }.freeze

    # 命令形式ごとのオペランドバイト数
    FORMAT_SIZES = {
      Z:   0,
      B:   1,
      BB:  2,
      BBB: 3,
      BS:  3,  # B(1) + S(2)
      BSS: 5,  # B(1) + S(2) + S(2)
      S:   2,
      W:   3,
    }.freeze

    def initialize(irep)
      @irep = irep
      @bytes = irep.instructions
      @pos = 0
    end

    def disassemble
      instructions = []
      @pos = 0
      bytes = @bytes.bytes

      while @pos < bytes.size
        offset = @pos
        opcode = bytes[@pos]
        @pos += 1

        op_info = OPCODES[opcode]
        if op_info.nil?
          instructions << { offset: offset, opcode: opcode, name: :OP_UNKNOWN, format: :Z, operands: [] }
          next
        end

        name, fmt = op_info
        operands = read_operands(bytes, fmt)
        instructions << { offset: offset, opcode: opcode, name: name, format: fmt, operands: operands }
      end

      instructions
    end

    def disassemble_to_s
      lines = []
      disassemble.each do |inst|
        line = format("%04d  %-14s", inst[:offset], inst[:name])
        line += format_operands(inst)
        lines << line
      end
      lines.join("\n")
    end

    private

    def read_operands(bytes, fmt)
      case fmt
      when :Z
        []
      when :B
        a = bytes[@pos]; @pos += 1
        [a]
      when :BB
        a = bytes[@pos]; b = bytes[@pos + 1]; @pos += 2
        [a, b]
      when :BBB
        a = bytes[@pos]; b = bytes[@pos + 1]; c = bytes[@pos + 2]; @pos += 3
        [a, b, c]
      when :BS
        a = bytes[@pos]
        b = (bytes[@pos + 1] << 8) | bytes[@pos + 2]
        @pos += 3
        [a, b]
      when :BSS
        a = bytes[@pos]
        b = (bytes[@pos + 1] << 8) | bytes[@pos + 2]
        c = (bytes[@pos + 3] << 8) | bytes[@pos + 4]
        @pos += 5
        [a, b, c]
      when :S
        a = (bytes[@pos] << 8) | bytes[@pos + 1]
        @pos += 2
        [a]
      when :W
        a = (bytes[@pos] << 16) | (bytes[@pos + 1] << 8) | bytes[@pos + 2]
        @pos += 3
        [a]
      else
        []
      end
    end

    def format_operands(inst)
      name = inst[:name]
      ops = inst[:operands]

      case name
      when :OP_MOVE
        "R[#{ops[0]}] = R[#{ops[1]}]"
      when :OP_LOADL
        pool_val = @irep.pool[ops[1]]
        "R[#{ops[0]}] = Pool[#{ops[1]}](#{pool_val})"
      when :OP_LOADI8
        val = ops[1] >= 128 ? ops[1] - 256 : ops[1]
        "R[#{ops[0]}] = #{val}"
      when :OP_LOADINEG
        "R[#{ops[0]}] = -#{ops[1]}"
      when :OP_LOADI__1
        "R[#{ops[0]}] = -1"
      when :OP_LOADI_0, :OP_LOADI_1, :OP_LOADI_2, :OP_LOADI_3,
           :OP_LOADI_4, :OP_LOADI_5, :OP_LOADI_6, :OP_LOADI_7
        val = name.to_s[-1].to_i
        "R[#{ops[0]}] = #{val}"
      when :OP_LOADI16
        val = ops[1] >= 32768 ? ops[1] - 65536 : ops[1]
        "R[#{ops[0]}] = #{val}"
      when :OP_LOADI32
        val = (ops[1] << 16) | ops[2]
        val -= 0x1_0000_0000 if val >= 0x8000_0000
        "R[#{ops[0]}] = #{val}"
      when :OP_LOADSELF
        "R[#{ops[0]}] = self"
      when :OP_LOADNIL
        "R[#{ops[0]}] = nil"
      when :OP_LOADTRUE
        "R[#{ops[0]}] = true"
      when :OP_LOADFALSE
        "R[#{ops[0]}] = false"
      when :OP_ADD
        "R[#{ops[0]}] = R[#{ops[0]}] + R[#{ops[0] + 1}]"
      when :OP_ADDI
        "R[#{ops[0]}] = R[#{ops[0]}] + #{ops[1]}"
      when :OP_SUB
        "R[#{ops[0]}] = R[#{ops[0]}] - R[#{ops[0] + 1}]"
      when :OP_SUBI
        "R[#{ops[0]}] = R[#{ops[0]}] - #{ops[1]}"
      when :OP_MUL
        "R[#{ops[0]}] = R[#{ops[0]}] * R[#{ops[0] + 1}]"
      when :OP_DIV
        "R[#{ops[0]}] = R[#{ops[0]}] / R[#{ops[0] + 1}]"
      when :OP_EQ
        "R[#{ops[0]}] = R[#{ops[0]}] == R[#{ops[0] + 1}]"
      when :OP_LT
        "R[#{ops[0]}] = R[#{ops[0]}] < R[#{ops[0] + 1}]"
      when :OP_LE
        "R[#{ops[0]}] = R[#{ops[0]}] <= R[#{ops[0] + 1}]"
      when :OP_GT
        "R[#{ops[0]}] = R[#{ops[0]}] > R[#{ops[0] + 1}]"
      when :OP_GE
        "R[#{ops[0]}] = R[#{ops[0]}] >= R[#{ops[0] + 1}]"
      when :OP_RETURN
        "R[#{ops[0]}]"
      when :OP_RETURN_BLK
        "R[#{ops[0]}] (block)"
      when :OP_SEND
        sym = @irep.symbols[ops[1]] || "sym_#{ops[1]}"
        "R[#{ops[0]}] = R[#{ops[0]}].#{sym}(#{ops[2]} args)"
      when :OP_SSEND
        sym = @irep.symbols[ops[1]] || "sym_#{ops[1]}"
        "R[#{ops[0]}] = self.#{sym}(#{ops[2]} args)"
      when :OP_JMP
        "-> #{ops[0]}"
      when :OP_JMPIF
        "if R[#{ops[0]}] -> #{ops[1]}"
      when :OP_JMPNOT
        "unless R[#{ops[0]}] -> #{ops[1]}"
      when :OP_JMPNIL
        "if R[#{ops[0]}].nil? -> #{ops[1]}"
      when :OP_ENTER
        "#{format('0x%06x', ops[0])}"
      when :OP_STOP
        ""
      when :OP_NOP
        ""
      when :OP_LOADSYM
        sym = @irep.symbols[ops[1]] || "sym_#{ops[1]}"
        "R[#{ops[0]}] = :#{sym}"
      when :OP_GETGV, :OP_SETGV, :OP_GETIV, :OP_SETIV,
           :OP_GETCV, :OP_SETCV, :OP_GETCONST, :OP_SETCONST
        sym = @irep.symbols[ops[1]] || "sym_#{ops[1]}"
        "R[#{ops[0]}], #{sym}"
      else
        ops.map(&:to_s).join(", ")
      end
    end
  end
end

# コマンドラインから実行した場合
if __FILE__ == $0
  if ARGV.empty?
    puts "Usage: ruby disasm.rb <file.mrb>"
    exit 1
  end

  data = File.binread(ARGV[0])
  parser = RubyOnPlc::MrbParser.new(data).parse

  puts "=== #{parser.header} ==="
  puts parser.irep
  puts

  disasm = RubyOnPlc::Disassembler.new(parser.irep)
  puts disasm.disassemble_to_s
end
