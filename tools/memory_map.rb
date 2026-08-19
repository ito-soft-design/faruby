# frozen_string_literal: true

# PLC メモリマップ定義
# EM (拡張データメモリ) のアドレス割り当てを定義します。
#
# 値スロット (4ワード) の構造
# ---------------------------
# レジスタ・定数プール・汎用グローバル変数は共通の「値スロット」形式で
# 格納します。1 スロット = 4 ワード (SLOT_WORDS)。
#
#   +0 : 型タグ (TT_*)          .U でアクセス
#   +1 : 値 下位ワード          ┐ .L でアクセス (+1 が起点)
#   +2 : 値 上位ワード          ┘
#   +3 : 予備 (将来の拡張用)
#
# 現時点で VM は整数のみを扱うため型タグは書き込まず TT_EMPTY (0) のまま
# ですが、Float・String・Array 等を導入する際にレジスタ幅を変更せずに
# 済むよう領域を予約しています。定数プールのみ、コンパイル時に型が
# 確定するため codegen が実際の型タグを書き込みます。

module MrubycOnPlc
  module MemoryMap
    # VM 状態領域
    VM_STATE_BASE     = 0
    PC_ADDR           = 0     # プログラムカウンタ
    STATUS_ADDR       = 1     # VM 状態 (0=停止, 1=実行中, 2=完了, 3=エラー)
    ERROR_ADDR        = 2     # エラーコード
    STEP_COUNT_ADDR   = 3     # 累計実行命令数 (.D = 2ワード)
    STEPS_PER_CYCLE   = 5     # 1スキャンあたり実行命令数
    CURRENT_OPCODE    = 6     # デバッグ: 現在のオペコード
    OPERAND_A         = 7     # デバッグ: オペランド a
    OPERAND_B         = 8     # デバッグ: オペランド b
    OPERAND_C         = 9     # デバッグ: オペランド c
    BYTECODE_LEN_ADDR = 10    # バイトコード長
    NREGS_ADDR        = 11    # レジスタ数
    NLOCALS_ADDR      = 12    # ローカル変数数
    RESET_REQ_ADDR    = 13    # リセット要求 (1=要求, PLC側で処理後0に戻る)
    NUM_SYMBOLS_ADDR  = 14    # シンボル数
    # 32ビット合成用スクラッチ (EM16=下位ワード, EM17=上位ワード)
    # KV スクリプトの EM はサフィックス無しだと 16ビット符号なしのため、
    # 負値や 65535 超の即値を組み立てるには一旦ここへ 2 ワードで置いてから
    # TEMP32.L として読み出す必要がある。
    TEMP32_ADDR       = 16

    # 値スロット 1 個あたりのワード数 (型タグ 1 + 値 2 + 予備 1)
    SLOT_WORDS        = 4
    # スロット内オフセット
    SLOT_TYPE_OFFSET  = 0     # 型タグ (TT_*)
    SLOT_VALUE_OFFSET = 1     # 値 (.L で 32ビット符号付き)

    # 値の型タグ (TT_*)
    # .mrb バイナリには実行時の型情報が含まれないため、本プロジェクトで
    # 定義した番号です (mruby/c の mrbc_vtype に倣った命名)。
    # TT_EMPTY = 0 はレジスタクリア直後の状態と一致します。
    TT_EMPTY          = 0     # 未初期化
    TT_NIL            = 1
    TT_FALSE          = 2
    TT_TRUE           = 3
    TT_INTEGER        = 4
    TT_FLOAT          = 5
    TT_SYMBOL         = 6
    TT_STRING         = 7     # 以降は未実装 (領域予約のみ)
    TT_ARRAY          = 8
    TT_HASH           = 9
    TT_OBJECT         = 10

    # レジスタファイル (4ワード/レジスタ = EM100-EM419)
    REG_FILE_BASE     = 100
    MAX_REGS          = 80

    # バイトコード領域 (1バイト/1EMレジスタ)
    BYTECODE_BASE     = 1000
    MAX_BYTECODE      = 3000

    # 定数プール (4ワード/エントリ = EM4000-EM4799)
    # デバイスマッピングテーブル (EM5000) と衝突しないよう 200 エントリまで
    POOL_BASE         = 4000
    MAX_POOL          = 200

    # デバイスマッピングテーブル (4ワード/エントリ = EM5000-EM5399)
    #   +0 : device_type   (DEVICE_TYPE_*)
    #   +1 : device_address
    #   +2 : access_type   (ACCESS_*)
    #   +3 : 予備
    DEVICE_TABLE_BASE = 5000
    DEVICE_TABLE_STRIDE = 4
    MAX_SYMBOLS       = 100

    # ワードデバイスのアクセス幅 (Ruby 側のサフィックス → KV サフィックス)
    #   $DM100   → ACCESS_S  (.S)  16ビット符号付き ※既定
    #   $DM100U  → ACCESS_U  (.U)  16ビット符号なし
    #   $DM100L  → ACCESS_L  (.L)  32ビット符号付き
    #   $DM100D  → ACCESS_D  (.D)  32ビット符号なし
    #   $DM100F  → ACCESS_F  (.F)  単精度実数 (未実装)
    ACCESS_S          = 0
    ACCESS_U          = 1
    ACCESS_L          = 2
    ACCESS_D          = 3
    ACCESS_F          = 4

    # Ruby シンボルのサフィックス文字 → ACCESS_*
    ACCESS_SUFFIXES = {
      ""  => ACCESS_S,   # 既定は16ビット符号付き
      "S" => ACCESS_S,
      "U" => ACCESS_U,
      "L" => ACCESS_L,
      "D" => ACCESS_D,
      "F" => ACCESS_F,
    }.freeze

    # ACCESS_* が占有するワード数
    ACCESS_WORDS = {
      ACCESS_S => 1, ACCESS_U => 1,
      ACCESS_L => 2, ACCESS_D => 2, ACCESS_F => 2,
    }.freeze

    ACCESS_NAMES = {
      ACCESS_S => "16bit符号付き", ACCESS_U => "16bit符号なし",
      ACCESS_L => "32bit符号付き", ACCESS_D => "32bit符号なし",
      ACCESS_F => "実数",
    }.freeze

    # デバイスタイプ定数
    DEVICE_TYPE_EM    = 0
    DEVICE_TYPE_DM    = 1
    DEVICE_TYPE_ZF    = 2
    DEVICE_TYPE_R     = 3
    DEVICE_TYPE_MR    = 4
    DEVICE_TYPE_B     = 5
    DEVICE_TYPE_L     = 6
    DEVICE_TYPE_CR    = 7
    DEVICE_TYPE_T     = 8
    DEVICE_TYPE_C     = 9

    # 汎用グローバル変数領域 (4ワード/変数)
    # デバイスマッピングテーブルには「値ワード」のアドレス
    # (= スロット先頭 + SLOT_VALUE_OFFSET) を格納します。これにより
    # GETGV/SETGV の EM デバイス経路をスロット非対応のまま流用できます。
    # 型タグは値ワードの 1 つ前 (スロット先頭) にあります。
    GENERAL_GLOBAL_BASE = 6000

    # VM 状態定数
    VM_STOPPED  = 0
    VM_RUNNING  = 1
    VM_FINISHED = 2
    VM_ERROR    = 3

    # デバイス名 (PLC 種別ごとに変更可能)
    DEVICE_NAME = "EM"

    module_function

    # VM レジスタ R[n] のスロット先頭 (型タグ) の EM アドレスを返す
    def reg_slot_addr(reg_index)
      REG_FILE_BASE + reg_index * SLOT_WORDS
    end

    # VM レジスタ R[n] の値ワードの EM アドレスを返す (.L アクセス用)
    def reg_addr(reg_index)
      reg_slot_addr(reg_index) + SLOT_VALUE_OFFSET
    end

    # VM レジスタ R[n] の型タグの EM アドレスを返す
    def reg_type_addr(reg_index)
      reg_slot_addr(reg_index) + SLOT_TYPE_OFFSET
    end

    # バイトコード byte[n] の EM アドレスを返す
    def bytecode_addr(byte_offset)
      BYTECODE_BASE + byte_offset
    end

    # 定数プール Pool[n] のスロット先頭 (型タグ) の EM アドレスを返す
    def pool_slot_addr(pool_index)
      POOL_BASE + pool_index * SLOT_WORDS
    end

    # 定数プール Pool[n] の値ワードの EM アドレスを返す (.L アクセス用)
    def pool_addr(pool_index)
      pool_slot_addr(pool_index) + SLOT_VALUE_OFFSET
    end

    # 定数プール Pool[n] の型タグの EM アドレスを返す
    def pool_type_addr(pool_index)
      pool_slot_addr(pool_index) + SLOT_TYPE_OFFSET
    end

    # 汎用グローバル変数 (n 番目) のスロット先頭の EM アドレスを返す
    def general_global_slot_addr(slot_index)
      GENERAL_GLOBAL_BASE + slot_index * SLOT_WORDS
    end

    # 汎用グローバル変数 (n 番目) の値ワードの EM アドレスを返す
    def general_global_addr(slot_index)
      general_global_slot_addr(slot_index) + SLOT_VALUE_OFFSET
    end

    # デバイス付きアドレス文字列を返す (例: "EM100")
    def device(addr)
      "#{DEVICE_NAME}#{addr}"
    end

    # 32ビットアクセス用デバイス文字列を返す (例: "EM100.L")
    def device_long(addr)
      "#{DEVICE_NAME}#{addr}.L"
    end
  end
end
