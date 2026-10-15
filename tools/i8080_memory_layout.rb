# frozen_string_literal: true

# i8080 用メモリレイアウト
#
# ND8080 ボード (32KB RAM: 0x8000-0xFFFF) を想定した固定メモリマップ。
# PLC 版 (MemoryLayout) が設定ファイルからアドレスを計算するのに対し、
# こちらはアドレスが固定で、ROM/RAM の境界も決まっています。
#
# すべてバイトアドレスです。PLC 版はワード (16 ビット) 単位ですが、
# i8080 は 8 ビット CPU なのでバイト単位で扱います。
#
# ## メモリマップ (ND8080: すべて RAM 0x8000-0xFFFF)
#
#   0x8000 - 0x80FF : VM 状態           (256B)
#   0x8100 - 0x81FF : レジスタファイル   (32 × 8B = 256B)
#   0x8200 - 0x82FF : IREP テーブル      (256B)
#   0x8300 - 0x83C6 : シンボルテーブル    (198B, GETGV/SETGV 用)
#   0x83C7 - 0x83F7 : === 除外 (割り込みベクタ) ===
#   0x83F8 - 0x83FF : (free)            (8B)
#   0x8400 - 0x8FFF : VM コード          (3KB, org 8400h)
#   0x9000 - 0x9FFF : mruby バイトコード (4KB)
#   0xA000 - 0xA7FF : 定数プール         (2KB)
#   0xA800 - 0xAFFF : (free)            (2KB)
#   0xB000 - 0xB0FF : グローバル変数      (256B, 64 スロット)
#   0xB100 - 0xB15F : フレームスタック    (96B, 8 フレーム × 12B)
#   0xB160 - 0xEFFF : (free)            (~16KB)
#   0xF000 - 0xFDFF : CPU スタック (SP)  (3.5KB)
#   0xFFB8 - 0xFFF7 : ND80Z モニタワーク (RST ベクタ, レジスタ退避等)
#   0xFFF8 - 0xFFFF : 7 セグ表示 (DIG)  (8B)
#
# ## バリュースロット
#
# レジスタ・定数プールは共通の「バリュースロット」形式で格納します。
# 1 スロット = 4 バイト。リトルエンディアン。
#
#   +0 : 型タグ (1 バイト)
#   +1 : 予約  (1 バイト, 常に 0)
#   +2 : 値 下位バイト (val_lo)  ┐ 値 (16 ビット, リトルエンディアン)
#   +3 : 値 上位バイト (val_hi)  ┘
#
# 型タグの番号は VmConstants の TT_* と同じです。

require_relative "vm_constants"

module FaRuby
  class I8080MemoryLayout
    include VmConstants

    # --- バリュースロット (16 ビット値) ---
    SLOT_BYTES        = 4
    SLOT_TYPE_OFFSET  = 0   # バイトオフセット
    SLOT_VALUE_OFFSET = 2   # バイトオフセット

    # --- RAM 領域 (ND8080: 0x8000-0xFFFF) ---
    RAM_BASE          = 0x8000

    VM_STATE_BASE     = 0x8000
    VM_STATE_SIZE     = 0x0100   # 256B

    REG_FILE_BASE     = 0x8100
    REG_FILE_SIZE     = 0x0100   # 256B
    MAX_REGS          = 64       # 256B / 4B = 64 スロット

    IREP_TABLE_BASE   = 0x8200
    IREP_TABLE_SIZE   = 0x0100   # 256B

    # 0x83C7-0x83F7 は ND8080 割り込みベクタのため除外

    VM_CODE_ORG       = 0x8400   # VM コードの org アドレス
    VM_CODE_SIZE      = 0x0C00   # 3KB

    BYTECODE_BASE     = 0x9000
    BYTECODE_SIZE     = 0x1000   # 4KB

    POOL_BASE         = 0xA000
    POOL_SIZE         = 0x0800   # 2KB

    # シンボルテーブル (OP_GETGV / OP_SETGV 用)
    # 各エントリ 2 バイト: グローバルスロットのアドレス (LE)
    # 0x0000 = 未対応のシンボル (メソッド名等)
    SYM_TABLE_BASE    = 0x8300
    SYM_TABLE_SIZE    = 0x00C6   # 198B (0x83C7 手前まで)
    MAX_SYMBOLS       = 99       # 198 / 2

    # グローバル変数スロット ($foo, $bar 等)
    # レジスタと同じ 4 バイト形式 (型タグ + 予約 + val_lo + val_hi)
    GLOBALS_BASE      = 0xB000
    GLOBALS_SIZE      = 0x0100   # 256B
    MAX_GLOBALS       = 64       # 256 / 4

    # CPU スタック (SP は下方向に伸びる。SP 初期値は STACK_TOP)
    STACK_BASE        = 0xF000
    STACK_TOP         = 0xFDFF   # SP 初期値
    STACK_SIZE        = 0x0E00   # 3.5KB

    # 7 セグメント表示バッファ (ND80Z モニタの DIG アドレス)
    DISPLAY_BASE      = 0xFFF8
    DISPLAY_SIZE      = 8        # 8 桁

    # --- フレームスタック ---
    #
    # ブロック呼び出し (times, loop) の復帰情報を保持するスタック。
    # 各フレームは 12 バイト:
    #
    #   +0,+1  return_pc       (2B)  復帰先 PC
    #   +2     return_irep     (1B)  復帰先 IREP 番号
    #   +3,+4  return_reg_base (2B)  復帰先レジスタベースアドレス
    #   +5     kind            (1B)  FRAME_KIND_*
    #   +6,+7  index           (2B)  現在の反復カウンタ
    #   +8,+9  limit           (2B)  反復上限
    #   +10    outer           (1B)  外側フレーム番号 (FRAME_NONE=トップレベル)
    #   +11    reserved        (1B)
    FRAME_STACK_BASE  = 0xB100
    FRAME_BYTES       = 12
    MAX_FRAMES        = 8
    FRAME_STACK_SIZE  = FRAME_BYTES * MAX_FRAMES  # 96B

    # フレームフィールドのバイトオフセット
    FRAME_OFF_RETURN_PC       = 0
    FRAME_OFF_RETURN_IREP     = 2
    FRAME_OFF_RETURN_REG_BASE = 3
    FRAME_OFF_KIND            = 5
    FRAME_OFF_INDEX           = 6
    FRAME_OFF_LIMIT           = 8
    FRAME_OFF_OUTER           = 10

    # フレーム種別
    FRAME_KIND_CALL    = 0   # メソッド呼び出し (将来用)
    FRAME_KIND_ITERATE = 1   # times / upto
    FRAME_KIND_LOOP    = 4   # loop (無限ループ)

    # 「外側フレームなし」を表す値 (トップレベル)
    FRAME_NONE = 0xFF

    # --- VM 状態領域のバイトオフセット ---
    #
    # 各フィールドはバイト境界で、16 ビット値は 2 バイト、
    # 32 ビット値は 4 バイトを占有します。
    #
    # PLC 版の OFFSET_* と対応関係がありますが、バイト単位で並べ直しています。
    OFFSET_PC              = 0x00   # 2B  プログラムカウンタ (バイトコード内オフセット)
    OFFSET_STATUS          = 0x02   # 2B  VM 状態 (VM_STOPPED, VM_RUNNING, ...)
    OFFSET_ERROR           = 0x04   # 2B  エラーコード
    OFFSET_STEP_COUNT      = 0x06   # 4B  実行ステップ数 (32 ビット)
    OFFSET_CURRENT_OPCODE  = 0x0A   # 1B  実行中のオペコード番号
    OFFSET_OPERAND_A       = 0x0B   # 1B  オペランド A
    OFFSET_OPERAND_B       = 0x0C   # 1B  オペランド B
    OFFSET_OPERAND_C       = 0x0D   # 1B  オペランド C
    OFFSET_BYTECODE_LEN    = 0x0E   # 2B  バイトコード長
    OFFSET_NREGS           = 0x10   # 1B  レジスタ数
    OFFSET_CUR_IREP        = 0x11   # 1B  現在の IREP 番号
    OFFSET_NUM_IREPS       = 0x12   # 1B  IREP 総数
    OFFSET_REG_BASE        = 0x14   # 2B  レジスタウィンドウのベースアドレス
    OFFSET_BC_BASE         = 0x16   # 2B  現在の IREP のバイトコード先頭アドレス
    OFFSET_FRAME_SP        = 0x18   # 1B  フレームスタックポインタ (0=トップレベル)
    OFFSET_SYM_BASE        = 0x19   # 2B  現在の IREP のシンボルテーブルアドレス

    # IREP テーブル 1 エントリのバイト数
    #
    #   +0  バイトコード先頭     (2B)
    #   +2  バイトコード長       (2B)
    #   +4  定数プール先頭       (2B)
    #   +6  nregs               (1B)
    #   +7  first_child         (1B)  最初の子 IREP 番号 (0xFF=子なし)
    #   +8  シンボルテーブル先頭  (2B)  この IREP のシンボルテーブルアドレス
    IREP_ENTRY_BYTES      = 10
    IREP_OFF_BYTECODE     = 0
    IREP_OFF_BYTECODE_LEN = 2
    IREP_OFF_POOL         = 4
    IREP_OFF_NREGS        = 6
    IREP_OFF_FIRST_CHILD  = 7
    IREP_OFF_SYM_TABLE    = 8

    # --- ヘルパーメソッド ---

    # レジスタスロットのアドレス
    def self.reg_slot_addr(index)
      REG_FILE_BASE + index * SLOT_BYTES
    end

    # レジスタの型タグのアドレス
    def self.reg_type_addr(index)
      reg_slot_addr(index) + SLOT_TYPE_OFFSET
    end

    # レジスタの値のアドレス (32 ビット値の先頭)
    def self.reg_value_addr(index)
      reg_slot_addr(index) + SLOT_VALUE_OFFSET
    end

    # 定数プールスロットのアドレス
    def self.pool_slot_addr(index)
      POOL_BASE + index * SLOT_BYTES
    end

    # 定数プールの型タグのアドレス
    def self.pool_type_addr(index)
      pool_slot_addr(index) + SLOT_TYPE_OFFSET
    end

    # 定数プールの値のアドレス
    def self.pool_value_addr(index)
      pool_slot_addr(index) + SLOT_VALUE_OFFSET
    end

    # IREP テーブルエントリのアドレス
    def self.irep_entry_addr(index)
      IREP_TABLE_BASE + index * IREP_ENTRY_BYTES
    end

    # VM 状態フィールドのアドレス
    def self.vm_state_addr(offset)
      VM_STATE_BASE + offset
    end

    # レジスタ番号からスロットアドレスを計算するアセンブリ用の情報
    #
    # i8080 は乗算命令が無いため、× 4 は 2 回の左シフトで行います。
    # A レジスタにレジスタ番号を入れて 2 回 ADD A すれば × 4 になり、
    # REG_FILE_BASE の下位バイトを足せばアドレスが出ます。
    # REG_FILE_BASE (0x8100) の下位バイトが 0x00 なので、
    # 上位バイトに 0x81 を入れるだけで済みます。
    def self.reg_addr_calc_note
      <<~NOTE
        ; レジスタ番号 (A) → HL にスロットアドレス
        ;   A = A << 2  (× 4)
        ;   L = A
        ;   H = 0x81    (REG_FILE_BASE >> 8)
      NOTE
    end

    # メモリマップの要約を文字列で返す (デバッグ・ドキュメント用)
    def self.summary
      <<~MAP
        i8080 Memory Map (ND8080 RAM: 0x8000-0xFFFF)
        ────────────────────────────────────────
        0x8000-0x80FF  VM state         (#{VM_STATE_SIZE}B)
        0x8100-0x81FF  Register file    (#{MAX_REGS} × #{SLOT_BYTES}B = #{REG_FILE_SIZE}B)
        0x8200-0x82FF  IREP table       (#{IREP_TABLE_SIZE}B)
        0x83C7-0x83F7  (excluded: interrupt vectors)
        0x8400-0x8FFF  VM code          (#{VM_CODE_SIZE / 1024}KB, org 8400h)
        0x9000-0x9FFF  Bytecode         (#{BYTECODE_SIZE / 1024}KB)
        0xA000-0xA7FF  Constant pool    (#{POOL_SIZE / 1024}KB)
        0xF000-0xFDFF  CPU stack        (#{STACK_SIZE}B)
        0xFFB8-0xFFF7  ND80Z monitor work
        0xFFF8-0xFFFF  7-seg display    (#{DISPLAY_SIZE}B)
      MAP
    end
  end
end
