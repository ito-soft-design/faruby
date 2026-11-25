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
      lines.concat(section_symbols_globals)
      lines.concat(section_frame_stack)
      lines.concat(section_method_table)
      lines.concat(section_object_pool)
      lines.concat(section_collection_pool)
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
      lines << equ("VM_ENTRY_POINT", layout::VM_ENTRY_POINT, width: 4, comment: "起動スタブ (通常 RAM)")
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
      lines << equ("INIT_METHOD_ID_STORE", layout::INIT_METHOD_ID_STORE, width: 4, comment: "initialize の method_id 格納アドレス")
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
      lines << equ("OFF_REG_BASE",      layout::OFFSET_REG_BASE,       comment: "2B  レジスタウィンドウのベースアドレス")
      lines << equ("OFF_BC_BASE",       layout::OFFSET_BC_BASE,        comment: "2B  現在の IREP のバイトコード先頭")
      lines << equ("OFF_FRAME_SP",      layout::OFFSET_FRAME_SP,       comment: "1B  フレームスタックポインタ")
      lines << equ("OFF_SYM_BASE",      layout::OFFSET_SYM_BASE,       comment: "2B  現在の IREP のシンボルテーブルアドレス")
      lines << equ("OFF_OBJ_SP",        layout::OFFSET_OBJ_SP,         comment: "1B  次の空きオブジェクトスロット")
      lines << equ("OFF_INIT_METHOD_ID", layout::OFFSET_INIT_METHOD_ID, comment: "1B  initialize のメソッド ID")
      lines << equ("OFF_POOL_BASE",    layout::OFFSET_POOL_BASE,      comment: "2B  現在の IREP の定数プール先頭")
      lines << equ("OFF_COL_SP",      layout::OFFSET_COL_SP,         comment: "1B  次の空きコレクションスロット")
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
      lines << equ("IREP_OFF_SUBTREE_SIZE", layout::IREP_OFF_SUBTREE_SIZE,  comment: "1B  DFS 前順サブツリーサイズ")
      lines << equ("IREP_OFF_SYM_TABLE",  layout::IREP_OFF_SYM_TABLE,    comment: "2B  シンボルテーブル先頭アドレス")
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
        "TT_STRING"  => TT_STRING,
        "TT_ARRAY"   => TT_ARRAY,
        "TT_HASH"    => TT_HASH,
        "TT_OBJECT"  => TT_OBJECT,
        "TT_PROC"    => TT_PROC,
        "TT_CLASS"   => TT_CLASS,
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

    # --- シンボルテーブル / グローバル変数 ---

    def section_symbols_globals
      layout = I8080MemoryLayout
      lines = []
      lines << "; --- シンボルテーブル / グローバル変数 ---"
      lines << ""
      lines << equ("SYM_TABLE_BASE",       layout::SYM_TABLE_BASE,       width: 4)
      lines << equ("GLOBALS_BASE",         layout::GLOBALS_BASE,         width: 4)
      # **数も出します。** 走査するところで `MAX_REGS` を「同じ 64 だから」と
      # 流用していて、片方を変えたときに気づけませんでした
      lines << equ("MAX_GLOBALS",          layout::MAX_GLOBALS,          comment: "グローバル変数の数")
      lines << ""
      lines << "; シンボル種別コード (上位バイト)"
      lines << equ("SYM_KIND_USER_METHOD", layout::SYM_KIND_USER_METHOD, comment: "ユーザー定義メソッド")
      lines << equ("SYM_KIND_CLASS",       layout::SYM_KIND_CLASS,       comment: "クラス名")
      lines << equ("SYM_KIND_IVAR",        layout::SYM_KIND_IVAR,        comment: "インスタンス変数")
      lines << ""
      lines
    end

    # --- フレームスタック ---

    def section_frame_stack
      layout = I8080MemoryLayout
      lines = []
      lines << "; --- フレームスタック ---"
      lines << ""
      lines << equ("FRAME_STACK_BASE",     layout::FRAME_STACK_BASE,     width: 4)
      lines << equ("FRAME_BYTES",          layout::FRAME_BYTES,          comment: "#{layout::FRAME_BYTES} バイト/フレーム")
      lines << equ("MAX_FRAMES",           layout::MAX_FRAMES)
      lines << ""
      lines << "; フレームフィールドのバイトオフセット"
      lines << equ("FRAME_OFF_RETURN_PC",      layout::FRAME_OFF_RETURN_PC,      comment: "2B")
      lines << equ("FRAME_OFF_RETURN_IREP",    layout::FRAME_OFF_RETURN_IREP,    comment: "1B")
      lines << equ("FRAME_OFF_RETURN_REG_BASE", layout::FRAME_OFF_RETURN_REG_BASE, comment: "2B")
      lines << equ("FRAME_OFF_KIND",           layout::FRAME_OFF_KIND,           comment: "1B")
      lines << equ("FRAME_OFF_INDEX",          layout::FRAME_OFF_INDEX,          comment: "2B")
      lines << equ("FRAME_OFF_LIMIT",          layout::FRAME_OFF_LIMIT,          comment: "2B")
      lines << equ("FRAME_OFF_OUTER",          layout::FRAME_OFF_OUTER,          comment: "1B")
      lines << ""
      lines << "; フレーム種別"
      lines << equ("FRAME_KIND_CALL",    layout::FRAME_KIND_CALL)
      lines << equ("FRAME_KIND_ITERATE", layout::FRAME_KIND_ITERATE, comment: "times / upto")
      lines << equ("FRAME_KIND_EACH",    layout::FRAME_KIND_EACH,    comment: "each (配列要素反復)")
      lines << equ("FRAME_KIND_LOOP",    layout::FRAME_KIND_LOOP,    comment: "loop (無限)")
      lines << equ("FRAME_KIND_NEW",     layout::FRAME_KIND_NEW,     comment: "Class#new → initialize")
      lines << ""
      lines << "; 外側フレームなし (トップレベル)"
      lines << equ("FRAME_NONE", layout::FRAME_NONE)
      lines << ""
      lines
    end

    # --- メソッド表 ---

    def section_method_table
      layout = I8080MemoryLayout
      lines = []
      lines << "; --- メソッド表 ---"
      lines << ""
      lines << equ("METHOD_TABLE_BASE",     layout::METHOD_TABLE_BASE,     width: 4)
      lines << equ("MAX_CLASSES",           layout::MAX_CLASSES)
      lines << equ("MAX_METHODS_PER_CLASS", layout::MAX_METHODS_PER_CLASS)
      lines << equ("METHOD_TABLE_SIZE",     layout::METHOD_TABLE_SIZE, width: 4)
      lines << equ("CLASS_MAIN",            layout::CLASS_MAIN)
      lines << equ("METHOD_NEW",            layout::METHOD_NEW,            comment: "Class#new")
      lines << equ("METHOD_DISPLAY",        layout::METHOD_DISPLAY,        comment: "display(value)")
      lines << equ("METHOD_GETKEY",         layout::METHOD_GETKEY,         comment: "getkey")
      lines << equ("METHOD_PUTS",           layout::METHOD_PUTS,           comment: "puts(value): ASCII 2 文字表示")
      lines << equ("METHOD_SETSEG",         layout::METHOD_SETSEG,         comment: "setseg(pos, pattern)")
      lines << equ("METHOD_RAND",          layout::METHOD_RAND,           comment: "rand(n)")
      lines << equ("METHOD_SLICE",         layout::METHOD_SLICE,          comment: "[](offset, length) 文字列スライス")
      lines << equ("METHOD_LENGTH",        layout::METHOD_LENGTH,         comment: "length / size")
      lines << equ("METHOD_CONCAT",        layout::METHOD_CONCAT,         comment: "<< (文字列追記/配列追加)")
      lines << equ("METHOD_EACH",          layout::METHOD_EACH,           comment: "each (配列要素反復)")
      lines << equ("METHOD_PUSH",          layout::METHOD_PUSH,           comment: "push (配列追加)")
      lines << equ("KEYIN1_ADDR",           layout::KEYIN1_ADDR,           width: 4, comment: "ND80Z モニタキー入力 (ブロッキング)")
      lines << equ("KEY_ADDR",              layout::KEY_ADDR,              width: 4, comment: "ND80Z キー 1 回スキャン (ノンブロッキング)")
      lines << ""
      lines << "; バンク切り替え (ND8080 拡張 RAM)"
      lines << equ("PORT_9C",          layout::PORT_9C,          comment: "I/O ポート 9C")
      lines << equ("PORT_9C_BANK_BIT", layout::PORT_9C_BANK_BIT, comment: "bit3: ROM/RAM 切替")
      lines << equ("CLONE_BUF",        layout::CLONE_BUF,        width: 4, comment: "ROM クローン用バッファ")
      lines << ""
      lines
    end

    # --- オブジェクトプール ---

    def section_object_pool
      layout = I8080MemoryLayout
      lines = []
      lines << "; --- オブジェクトプール ---"
      lines << ""
      lines << equ("OBJECT_POOL_BASE",   layout::OBJECT_POOL_BASE,   width: 4)
      lines << equ("MAX_OBJECTS",        layout::MAX_OBJECTS)
      lines << equ("OBJECT_SLOT_SIZE",   layout::OBJECT_SLOT_SIZE,   comment: "32B/スロット")
      lines << equ("OBJECT_HEADER_SIZE", layout::OBJECT_HEADER_SIZE)
      lines << equ("MAX_IVARS",          layout::MAX_IVARS)
      lines << ""
      lines
    end

    # --- コレクションプール ---

    def section_collection_pool
      layout = I8080MemoryLayout
      lines = []
      lines << "; --- コレクションプール (文字列・配列) ---"
      lines << ""
      lines << equ("COLLECTION_POOL_BASE", layout::COLLECTION_POOL_BASE, width: 4)
      lines << equ("MAX_COL_SLOTS",        layout::MAX_COL_SLOTS)
      lines << equ("COL_SLOT_SIZE",        layout::COL_SLOT_SIZE,        comment: "36B/スロット")
      lines << equ("COL_HEADER_SIZE",      layout::COL_HEADER_SIZE,      comment: "+0: type, +1: count")
      lines << equ("COL_DATA_SIZE",        layout::COL_DATA_SIZE,        comment: "データ領域 (34B)")
      lines << equ("COL_MAX_STRING_LEN",   layout::COL_MAX_STRING_LEN)
      lines << equ("COL_MAX_ARRAY_ELEMS",  layout::COL_MAX_ARRAY_ELEMS)
      lines << equ("COL_TYPE_FREE",        layout::COL_TYPE_FREE)
      lines << equ("COL_TYPE_STRING",      layout::COL_TYPE_STRING)
      lines << equ("COL_TYPE_ARRAY",       layout::COL_TYPE_ARRAY)
      lines << equ("COL_TYPE_HASH",        layout::COL_TYPE_HASH)
      lines << equ("HASH_PAIR_BYTES",      layout::HASH_PAIR_BYTES,       comment: "8B/ペア (key+value)")
      lines << equ("COL_MAX_HASH_PAIRS",   layout::COL_MAX_HASH_PAIRS,    comment: "最大4ペア")
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
