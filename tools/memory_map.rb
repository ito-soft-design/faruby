# frozen_string_literal: true

# PLC メモリマップ定義
# EM (拡張データメモリ) のアドレス割り当てを定義します。

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

    # レジスタファイル (32ビット符号付き = 2ワード/レジスタ)
    REG_FILE_BASE     = 100
    MAX_REGS          = 80

    # バイトコード領域 (1バイト/1EMレジスタ)
    BYTECODE_BASE     = 1000
    MAX_BYTECODE      = 3000

    # 定数プール (32ビット符号付き = 2ワード/エントリ)
    POOL_BASE         = 4000
    MAX_POOL          = 250

    # VM 状態定数
    VM_STOPPED  = 0
    VM_RUNNING  = 1
    VM_FINISHED = 2
    VM_ERROR    = 3

    # デバイス名 (PLC 種別ごとに変更可能)
    DEVICE_NAME = "EM"

    module_function

    # VM レジスタ R[n] の EM アドレスを返す
    def reg_addr(reg_index)
      REG_FILE_BASE + reg_index * 2
    end

    # バイトコード byte[n] の EM アドレスを返す
    def bytecode_addr(byte_offset)
      BYTECODE_BASE + byte_offset
    end

    # 定数プール Pool[n] の EM アドレスを返す
    def pool_addr(pool_index)
      POOL_BASE + pool_index * 2
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
