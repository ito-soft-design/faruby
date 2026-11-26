# frozen_string_literal: true

require_relative "disasm"
require_relative "vm_constants"

module FaRuby
  # `Array.new(n)` の n がプログラムに書いてあるときだけ、転送する前に見る
  #
  # **実行時にも止まります** (`ERROR=10`)。ここで見るのは、数が定数なら
  # PLC へ送る前に分かるからです。**上限は機種で違う**ので (PLC は 12、
  # i8080 は 8)、判定は呼ぶ側に任せて大きさだけ返します。
  #
  # **見えるのは定数だけです。** `Array.new(n)` の n が変数なら実行時まで
  # 分かりません。見逃しは許しますが、**誤って止めることはしません** —
  # register を書く命令はすべて「分からなくなった」として扱います。
  module ArrayNewSizes
    # 1 命令で即値をレジスタに載せる命令。[命令名] => 値の求め方
    LITERALS = {
      OP_LOADI_0: ->(_ops) { 0 },
      OP_LOADI_1: ->(_ops) { 1 },
      OP_LOADI_2: ->(_ops) { 2 },
      OP_LOADI_3: ->(_ops) { 3 },
      OP_LOADI_4: ->(_ops) { 4 },
      OP_LOADI_5: ->(_ops) { 5 },
      OP_LOADI_6: ->(_ops) { 6 },
      OP_LOADI_7: ->(_ops) { 7 },
      OP_LOADI__1: ->(_ops) { -1 },
      OP_LOADI: ->(ops) { ops[1].to_i },
      OP_LOADINEG: ->(ops) { -ops[1].to_i },
      OP_LOADI16: ->(ops) { to_signed16(ops[1].to_i) },
    }.freeze

    # 飛び先では何が載っているか分からない。全部忘れる
    JUMPS = %i[OP_JMP OP_JMPIF OP_JMPNOT OP_JMPNIL OP_BREAK OP_RETURN].freeze

    def self.to_signed16(value) = value >= 0x8000 ? value - 0x10000 : value

    # 見つかった大きさの一覧。[{size:, block:}] を返す
    #
    # block は `Array.new(n) { }` の形かどうか。どちらも同じ上限です。
    def self.scan(ireps)
      ireps.flat_map { |irep| scan_irep(irep) }
    end

    def self.scan_irep(irep)
      found = []
      arrays = {}    # レジスタ => Array クラスが載っている
      sizes = {}     # レジスタ => 載っている整数

      Disassembler.new(irep).disassemble.each do |inst|
        name = inst[:name]
        ops = inst[:operands]

        if JUMPS.include?(name)
          arrays.clear
          sizes.clear
          next
        end

        reg = ops[0].to_i

        if name == :OP_GETCONST
          sizes.delete(reg)
          symbol = irep.symbols[ops[1].to_i]
          arrays[reg] = true if symbol == "Array"
          arrays.delete(reg) unless symbol == "Array"
          next
        end

        if (literal = LITERALS[name])
          arrays.delete(reg)
          sizes[reg] = literal.call(ops)
          next
        end

        if %i[OP_SEND OP_SENDB].include?(name) &&
           irep.symbols[ops[1].to_i] == "new" && arrays[reg] &&
           ops[2].to_i >= 1 && sizes.key?(reg + 1)
          found << { size: sizes[reg + 1], block: name == :OP_SENDB }
        end

        # **書いた先は分からなくなります。** 見逃す側に倒します
        arrays.delete(reg)
        sizes.delete(reg)
      end

      found
    end
  end
end
