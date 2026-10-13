# frozen_string_literal: true

# i8080 アセンブリ用 EQU ヘッダ生成
#
# VmConstants・OpcodeTable・I8080MemoryLayout の定数を .a80 の EQU 定義として
# 出力します。アセンブリ側は `.include vm_constants.a80` で取り込みます。
#
# 使い方:
#   ruby tools/i8080_constants_gen.rb > plc/i8080/r8080/vm_constants.a80
#
# asm80 の制約:
#   - 16 進数は末尾に h を付け、先頭が A-F なら 0 を付ける (0FFh 等)
#   - EQU の左辺はラベルで、大文字小文字は区別しない

require_relative "vm_constants"
require_relative "opcode_table"
require_relative "i8080_memory_layout"

module FaRuby
  module I8080ConstantsGen
    include VmConstants

    module_function

    # Phase 1 で実装するオペコード名の一覧
    PHASE1_OPCODES = %i[
      OP_NOP OP_MOVE OP_LOADI OP_LOADINEG OP_LOADI__1
      OP_LOADI_0 OP_LOADI_1 OP_LOADI_2 OP_LOADI_3
      OP_LOADI_4 OP_LOADI_5 OP_LOADI_6 OP_LOADI_7
      OP_LOADI16 OP_LOADNIL OP_LOADT OP_LOADF
      OP_ADD OP_SUB OP_EQ OP_LT OP_LE OP_GT OP_GE
      OP_JMP OP_JMPIF OP_JMPNOT OP_STOP
    ].freeze

    # 16 進数を asm80 形式に変換する
    #
    # asm80 は先頭が A-F の場合に数値と認識しないため、0 を付ける。
    # 幅を指定すると 0 埋めされる (2 なら 2 桁、4 なら 4 桁)。
    def hex(value, width = 2)
      s = format("%0#{width}Xh", value & (width == 4 ? 0xFFFF : 0xFF))
      s = "0#{s}" if s[0] =~ /[A-Fa-f]/
      s
    end

    # EQU 1 行を生成する
    def equ(name, value, width: 2, comment: nil)
      line = format("%-24s EQU  %s", name, hex(value, width))
      line += "  ; #{comment}" if comment
      line
    end

    # ヘッダ全体を生成する
    def generate
      lines = []
      lines << "; vm_constants.a80 — 自動生成 (i8080_constants_gen.rb)"
      lines << "; このファイルは手で書き換えないでください"
      lines << ""

      lines.concat(section_memory_layout)
      lines.concat(section_slot)
      lines.concat(section_vm_state_offsets)
      lines.concat(section_irep_entry)
      lines.concat(section_type_tags)
      lines.concat(section_vm_status)
      lines.concat(section_opcodes)
      lines.concat(section_opcode_formats)

      lines.join("\n") + "\n"
    end

    # --- メモリマップ ---

    def section_memory_layout
      layout = I8080MemoryLayout
      lines = []
      lines << "; --- メモリマップ ---"
      lines << ""
      lines << equ("VM_CODE_ORG",    layout::VM_CODE_ORG,    width: 4)
      lines << equ("BYTECODE_BASE",  layout::BYTECODE_BASE,  width: 4)
      lines << equ("BYTECODE_SIZE",  layout::BYTECODE_SIZE,  width: 4)
      lines << equ("POOL_BASE",      layout::POOL_BASE,      width: 4)
      lines << equ("IREP_TABLE_BASE", layout::IREP_TABLE_BASE, width: 4)
      lines << equ("VM_STATE_BASE",  layout::VM_STATE_BASE,  width: 4)
      lines << equ("REG_FILE_BASE",  layout::REG_FILE_BASE,  width: 4)
      lines << equ("REG_FILE_BASE_HI", layout::REG_FILE_BASE >> 8, comment: "REG_FILE_BASE の上位バイト")
      lines << equ("MAX_REGS",       layout::MAX_REGS)
      lines << equ("STACK_TOP",      layout::STACK_TOP,      width: 4)
      lines << equ("DISPLAY_BASE",   layout::DISPLAY_BASE,   width: 4)
      lines << equ("DISPLAY_SIZE",   layout::DISPLAY_SIZE)
      lines << ""
      lines
    end

    # --- バリュースロット ---

    def section_slot
      layout = I8080MemoryLayout
      lines = []
      lines << "; --- バリュースロット ---"
      lines << ""
      lines << equ("SLOT_BYTES",        layout::SLOT_BYTES,        comment: "1 スロットのバイト数")
      lines << equ("SLOT_TYPE_OFFSET",  layout::SLOT_TYPE_OFFSET,  comment: "型タグのバイトオフセット")
      lines << equ("SLOT_VALUE_OFFSET", layout::SLOT_VALUE_OFFSET, comment: "値のバイトオフセット")
      lines << ""
      lines
    end

    # --- VM 状態領域のオフセット ---

    def section_vm_state_offsets
      layout = I8080MemoryLayout
      lines = []
      lines << "; --- VM 状態領域のオフセット ---"
      lines << ""
      lines << equ("OFF_PC",             layout::OFFSET_PC,             comment: "2B")
      lines << equ("OFF_STATUS",         layout::OFFSET_STATUS,         comment: "2B")
      lines << equ("OFF_ERROR",          layout::OFFSET_ERROR,          comment: "2B")
      lines << equ("OFF_STEP_COUNT",     layout::OFFSET_STEP_COUNT,     comment: "4B")
      lines << equ("OFF_CURRENT_OPCODE", layout::OFFSET_CURRENT_OPCODE, comment: "1B")
      lines << equ("OFF_OPERAND_A",      layout::OFFSET_OPERAND_A,      comment: "1B")
      lines << equ("OFF_OPERAND_B",      layout::OFFSET_OPERAND_B,      comment: "1B")
      lines << equ("OFF_OPERAND_C",      layout::OFFSET_OPERAND_C,      comment: "1B")
      lines << equ("OFF_BYTECODE_LEN",   layout::OFFSET_BYTECODE_LEN,   comment: "2B")
      lines << equ("OFF_NREGS",          layout::OFFSET_NREGS,          comment: "1B")
      lines << equ("OFF_CUR_IREP",       layout::OFFSET_CUR_IREP,       comment: "1B")
      lines << equ("OFF_NUM_IREPS",      layout::OFFSET_NUM_IREPS,      comment: "1B")
      lines << ""
      lines
    end

    # --- IREP テーブル ---

    def section_irep_entry
      layout = I8080MemoryLayout
      lines = []
      lines << "; --- IREP テーブルエントリ ---"
      lines << ""
      lines << equ("IREP_ENTRY_BYTES",     layout::IREP_ENTRY_BYTES)
      lines << equ("IREP_OFF_BYTECODE",    layout::IREP_OFF_BYTECODE,     comment: "2B")
      lines << equ("IREP_OFF_BYTECODE_LEN", layout::IREP_OFF_BYTECODE_LEN, comment: "2B")
      lines << equ("IREP_OFF_POOL",        layout::IREP_OFF_POOL,         comment: "2B")
      lines << equ("IREP_OFF_NREGS",       layout::IREP_OFF_NREGS,        comment: "1B")
      lines << ""
      lines
    end

    # --- 型タグ ---

    def section_type_tags
      lines = []
      lines << "; --- 型タグ ---"
      lines << "; TT_FALSY_MAX 以下が偽 (nil, false)"
      lines << ""
      {
        "TT_EMPTY"   => TT_EMPTY,
        "TT_NIL"     => TT_NIL,
        "TT_FALSE"   => TT_FALSE,
        "TT_TRUE"    => TT_TRUE,
        "TT_INTEGER" => TT_INTEGER,
        "TT_FALSY_MAX" => TT_FALSY_MAX,
      }.each do |name, value|
        lines << equ(name, value)
      end
      lines << ""
      lines
    end

    # --- VM 状態 ---

    def section_vm_status
      lines = []
      lines << "; --- VM 実行状態 ---"
      lines << ""
      lines << equ("VM_STOPPED",  VM_STOPPED)
      lines << equ("VM_RUNNING",  VM_RUNNING)
      lines << equ("VM_FINISHED", VM_FINISHED)
      lines << equ("VM_ERROR",    VM_ERROR)
      lines << ""
      lines
    end

    # --- オペコード ---

    def section_opcodes
      lines = []
      lines << "; --- Phase 1 オペコード ---"
      lines << ""
      PHASE1_OPCODES.each do |name|
        entry = OpcodeTable::MRUBY_OPCODES.find { |_code, (n, _fmt)| n == name }
        raise "未知のオペコード: #{name}" unless entry

        code, (opname, _fmt) = entry
        lines << equ(opname.to_s, code)
      end
      lines << ""
      lines
    end

    # --- 命令形式ごとのオペランドバイト数 ---

    def section_opcode_formats
      lines = []
      lines << "; --- 命令形式ごとのオペランドバイト数 ---"
      lines << "; 命令長 = 1 (オペコード) + オペランドバイト数"
      lines << ""
      OpcodeTable::FORMAT_SIZES.each do |fmt, size|
        lines << equ("FMT_#{fmt}", size, comment: "#{fmt} 形式のオペランドバイト数")
      end
      lines << ""
      lines
    end
  end
end

# 直接実行で標準出力に書き出す
if $PROGRAM_NAME == __FILE__
  puts FaRuby::I8080ConstantsGen.generate
end
