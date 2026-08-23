# frozen_string_literal: true

# mruby バイトコード逆アセンブラ
# IREP の命令バイト列を人間が読める形式にデコードします。

require_relative "mrb_parser"
require_relative "opcode_table"

module FaRuby
  class Disassembler
    # オペコード定義は tools/opcode_table.rb に一本化されている
    # (実装済みの命令より広い集合。未実装の命令も逆アセンブルできる)
    OPCODES = OpcodeTable::MRUBY_OPCODES
    FORMAT_SIZES = OpcodeTable::FORMAT_SIZES

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
      when :OP_LOADI
        # オペランドは符号なし (負値は OP_LOADINEG)
        "R[#{ops[0]}] = #{ops[1]}"
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
      when :OP_LOADT
        "R[#{ops[0]}] = true"
      when :OP_LOADF
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
      when :OP_GETGV, :OP_GETIV, :OP_GETCV, :OP_GETCONST
        sym = @irep.symbols[ops[1]] || "sym_#{ops[1]}"
        "R[#{ops[0]}], #{sym}"
      when :OP_SETGV, :OP_SETIV, :OP_SETCV, :OP_SETCONST
        sym = @irep.symbols[ops[1]] || "sym_#{ops[1]}"
        "#{sym}, R[#{ops[0]}]"
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
  parser = FaRuby::MrbParser.new(data).parse

  puts "=== #{parser.header} ==="
  puts parser.irep
  puts

  disasm = FaRuby::Disassembler.new(parser.irep)
  puts disasm.disassemble_to_s
end
