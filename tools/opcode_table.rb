# frozen_string_literal: true

# オペコード定義表
#
# PLC 側 VM (plc/keyence/vm_core.kvs) はこの表から生成します。
# 命令を追加・変更する場合は vm_core.kvs を直接編集せず、この表を直してから
# `rake vm_core` で再生成してください。
#
# 各定義は以下を持ちます。
#   code    : オペコード番号
#   name    : 命令名 (mruby の OP_*)
#   format  : 命令形式 (:Z :B :BB :BBB :S :BS :BSS)
#             オペランドのフェッチコードは形式から自動生成されます。
#             B=1バイト、S=2バイト(ビッグエンディアン)。
#             オペランドは順に a, b, c として参照できます。
#   summary : 生成コードに入れるコメント
#   body    : 命令の動作を組み立てるブロック (エミッタを受け取る)
#
# この表には PLC 機種固有の名前 (デバイス名・インデックスレジスタ) を
# 書かないでください。格納先の実体はエミッタ側が決めます。
#   悪い例: e.line "EM16 = EM8"
#   良い例: e.line "#{e.scratch_lo} = #{e.operand(:b)}"
# test_kvs_generator.rb がこの規約を検証します。

require_relative "memory_map"

module MrubycOnPlc
  # 1 命令の定義
  class OpcodeDef
    attr_reader :code, :name, :format, :summary, :body

    def initialize(code, name, format, summary, &body)
      @code = code
      @name = name
      @format = format
      @summary = summary
      @body = body
    end

    # 生成コードの見出しコメント (例: "OP_MOVE (BB): R[a] = R[b]")
    def header_comment
      "#{name} (#{format}): #{summary}"
    end
  end

  module OpcodeTable
    module_function

    # 全オペコード定義 (コード順)
    def all
      @all ||= build.sort_by(&:code).freeze
    end

    # オペコード番号の集合
    def codes
      all.map(&:code)
    end

    def build
      defs = []

      defs << OpcodeDef.new(0x00, :OP_NOP, :Z, "何もしない") { |_e| }

      defs << OpcodeDef.new(0x01, :OP_MOVE, :BB, "R[a] = R[b]") do |e|
        e.line "#{e.reg(1, :a)} = #{e.reg(2, :b)}"
      end

      defs << OpcodeDef.new(0x02, :OP_LOADL, :BB, "R[a] = Pool[b]") do |e|
        e.line "#{e.reg(1, :a)} = #{e.pool(2, :b)}"
      end

      defs << OpcodeDef.new(0x03, :OP_LOADI8, :BB, "R[a] = signed(b)") do |e|
        e.comment "8ビット値を符号拡張して32ビットスクラッチに置く"
        e.comment "16ビット符号なしのまま引き算すると桁が壊れるため"
        e.sign_extend_to_scratch(:b, 8)
        e.line "#{e.reg(1, :a)} = #{e.scratch32}"
      end

      defs << OpcodeDef.new(0x04, :OP_LOADINEG, :BB, "R[a] = -b") do |e|
        e.comment "2の補数を32ビットで組み立てる"
        e.line "#{e.scratch_lo} = 0 - #{e.operand(:b)}"
        e.line "#{e.scratch_hi} = 0"
        e.if_block("#{e.operand(:b)} <> 0") { e.line "#{e.scratch_hi} = 65535" }
        e.line "#{e.reg(1, :a)} = #{e.scratch32}"
      end

      defs << OpcodeDef.new(0x05, :OP_LOADI__1, :B, "R[a] = -1") do |e|
        e.line "#{e.reg(1, :a)} = -1"
      end

      # OP_LOADI_0 ~ OP_LOADI_7 (0x06-0x0D)
      (0..7).each do |n|
        defs << OpcodeDef.new(0x06 + n, :"OP_LOADI_#{n}", :B, "R[a] = #{n}") do |e|
          e.line "#{e.reg(1, :a)} = #{n}"
        end
      end

      defs << OpcodeDef.new(0x0E, :OP_LOADI16, :BS, "R[a] = signed16(b)") do |e|
        e.comment "下位ワードは既に2の補数のビット列なので符号拡張のみ行う"
        e.sign_extend_to_scratch(:b, 16)
        e.line "#{e.reg(1, :a)} = #{e.scratch32}"
      end

      defs << OpcodeDef.new(0x0F, :OP_LOADI32, :BSS, "R[a] = (b<<16)+c") do |e|
        e.comment "b * 65536 は16ビット演算になり桁上がりが落ちるため、"
        e.comment "下位/上位ワードを並べて32ビットとして読む"
        e.line "#{e.scratch_lo} = #{e.operand(:c)}"
        e.line "#{e.scratch_hi} = #{e.operand(:b)}"
        e.line "#{e.reg(1, :a)} = #{e.scratch32}"
      end

      defs << OpcodeDef.new(0x11, :OP_LOADNIL, :B, "R[a] = nil (=0)") do |e|
        e.line "#{e.reg(1, :a)} = 0"
      end

      defs << OpcodeDef.new(0x12, :OP_LOADSELF, :B, "R[a] = self (=0)") do |e|
        e.line "#{e.reg(1, :a)} = 0"
      end

      defs << OpcodeDef.new(0x13, :OP_LOADTRUE, :B, "R[a] = 1") do |e|
        e.line "#{e.reg(1, :a)} = 1"
      end

      defs << OpcodeDef.new(0x14, :OP_LOADFALSE, :B, "R[a] = 0") do |e|
        e.line "#{e.reg(1, :a)} = 0"
      end

      defs << OpcodeDef.new(0x15, :OP_GETGV, :BB, "R[a] = global[symbols[b]]") do |e|
        e.device_table_lookup(:b)
        e.comment "レジスタアドレス"
        e.device_dispatch(:read, reg: e.reg(2, :a), error_code: 0x15)
      end

      defs << OpcodeDef.new(0x16, :OP_SETGV, :BB, "global[symbols[b]] = R[a]") do |e|
        e.device_table_lookup(:b)
        e.comment "レジスタアドレス"
        e.device_dispatch(:write, reg: e.reg(2, :a), error_code: 0x16)
      end

      defs << OpcodeDef.new(0x25, :OP_JMP, :S, "PC += signed16(a)") do |e|
        e.signed16(:a)
        e.jump_relative(:a)
      end

      defs << OpcodeDef.new(0x26, :OP_JMPIF, :BS, "if R[a] <> 0 then PC += signed16(b)") do |e|
        e.signed16(:b)
        e.if_block("#{e.reg(1, :a)} <> 0") { e.jump_relative(:b) }
      end

      defs << OpcodeDef.new(0x27, :OP_JMPNOT, :BS, "if R[a] = 0 then PC += signed16(b)") do |e|
        e.signed16(:b)
        e.if_block("#{e.reg(1, :a)} = 0") { e.jump_relative(:b) }
      end

      defs << OpcodeDef.new(0x28, :OP_JMPNIL, :BS, "if R[a] = 0 (nil) then PC += signed16(b)") do |e|
        e.signed16(:b)
        e.if_block("#{e.reg(1, :a)} = 0") { e.jump_relative(:b) }
      end

      defs << OpcodeDef.new(0x38, :OP_RETURN, :B, "トップレベルでは VM 停止") do |e|
        e.vm_finish
      end

      # 二項算術: R[a] = R[a] <op> R[a+1]
      {
        0x3C => [:OP_ADD, "+"],
        0x3E => [:OP_SUB, "-"],
        0x40 => [:OP_MUL, "*"],
      }.each do |code, (name, op)|
        defs << OpcodeDef.new(code, name, :B, "R[a] = R[a] #{op} R[a+1]") do |e|
          lhs = e.reg(1, :a)
          rhs = e.reg_next(2, :a)
          e.line "#{lhs} = #{lhs} #{op} #{rhs}"
        end
      end

      # 即値算術: R[a] = R[a] <op> b
      {
        0x3D => [:OP_ADDI, "+"],
        0x3F => [:OP_SUBI, "-"],
      }.each do |code, (name, op)|
        defs << OpcodeDef.new(code, name, :BB, "R[a] = R[a] #{op} b") do |e|
          lhs = e.reg(1, :a)
          e.line "#{lhs} = #{lhs} #{op} #{e.operand(:b)}"
        end
      end

      defs << OpcodeDef.new(0x41, :OP_DIV, :B, "R[a] = R[a] / R[a+1]") do |e|
        lhs = e.reg(1, :a)
        rhs = e.reg_next(2, :a)
        e.if_else_block("#{rhs} <> 0") do
          e.line "#{lhs} = #{lhs} / #{rhs}"
        end
        e.vm_error(1) # division by zero
        e.end_block
      end

      # 比較: R[a] = (R[a] <op> R[a+1]) ? 1 : 0
      {
        0x42 => [:OP_EQ, "="],
        0x43 => [:OP_LT, "<"],
        0x44 => [:OP_LE, "<="],
        0x45 => [:OP_GT, ">"],
        0x46 => [:OP_GE, ">="],
      }.each do |code, (name, op)|
        defs << OpcodeDef.new(code, name, :B, "R[a] = (R[a] #{op} R[a+1]) ? 1 : 0") do |e|
          lhs = e.reg(1, :a)
          rhs = e.reg_next(2, :a)
          e.if_else_block("#{lhs} #{op} #{rhs}") { e.line "#{lhs} = 1" }
          e.line "#{lhs} = 0"
          e.end_block
        end
      end

      defs << OpcodeDef.new(0x69, :OP_STOP, :Z, "VM 停止") do |e|
        e.vm_finish
      end

      defs
    end
  end
end
