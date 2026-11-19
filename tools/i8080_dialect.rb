# frozen_string_literal: true

# i8080 バックエンド用オペコード選別
#
# PLC 版の Dialect は KV スクリプト / ST の綴り方を差し替えるものですが、
# i8080 版は手書きアセンブリなので「綴り方」は持ちません。
# **このクラスが持つのは Phase 1 で対応するオペコードの一覧と、
# OpcodeTable から必要な命令を選び出す機能だけです。**
#
# Dialect::CLASSES には追加しません (rake vm_core は PLC 専用)。
# rake i8080:* の専用タスクから使います。

require_relative "opcode_table"

module FaRuby
  class I8080Dialect
    # Phase 1: 整数演算・比較・分岐の約 20 オペコード
    #
    # テスト目標: `a = 1 + 2` → R[1] = 3, 7 セグに "00000003"
    PHASE1 = %i[
      OP_NOP OP_MOVE
      OP_LOADI OP_LOADINEG OP_LOADI__1
      OP_LOADI_0 OP_LOADI_1 OP_LOADI_2 OP_LOADI_3
      OP_LOADI_4 OP_LOADI_5 OP_LOADI_6 OP_LOADI_7
      OP_LOADI16
      OP_LOADNIL OP_LOADT OP_LOADF
      OP_ADD OP_SUB
      OP_EQ OP_LT OP_LE OP_GT OP_GE
      OP_JMP OP_JMPIF OP_JMPNOT
      OP_STOP
    ].freeze

    # Phase 1 のオペコード名からコード番号への対応表
    #
    # アセンブリ側のジャンプテーブル生成や、バイトコードのフィルタリングに使います。
    def self.phase1_codes
      @phase1_codes ||= PHASE1.map { |name|
        entry = OpcodeTable::MRUBY_OPCODES.find { |_code, (n, _fmt)| n == name }
        raise "未知のオペコード: #{name}" unless entry

        [name, entry[0]]
      }.to_h.freeze
    end

    # Phase 1 のコード番号の集合
    def self.phase1_code_set
      @phase1_code_set ||= phase1_codes.values.to_set.freeze
    end

    # OpcodeTable の全命令定義から Phase 1 のものだけを選ぶ
    def self.select_opcodes(opcodes = OpcodeTable.all)
      opcodes.select { |op| phase1_code_set.include?(op.code) }
    end

    # Phase 1 で使うオペコードの最大番号
    #
    # ジャンプテーブルの大きさを決めるのに使います。
    def self.max_opcode
      phase1_codes.values.max
    end

    # アセンブリのジャンプテーブル用: コード番号 => ラベル名の対応
    #
    # Phase 1 に無い番号は nil を返し、呼び出し側が vm_error へ飛ぶ
    # ラベルを入れます。
    def self.jump_table
      max = max_opcode
      (0..max).map { |code|
        entry = OpcodeTable::MRUBY_OPCODES[code]
        if entry && phase1_code_set.include?(code)
          [code, "do_#{entry[0].to_s.downcase}"]
        else
          [code, nil]
        end
      }
    end
  end
end
