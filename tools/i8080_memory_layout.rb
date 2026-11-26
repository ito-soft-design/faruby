# frozen_string_literal: true

# i8080 用メモリレイアウト
#
# ND8080 ボード (拡張 RAM 搭載時: 0x0000-0xFFFF 全域 RAM) の
# 固定メモリマップ。PLC 版 (MemoryLayout) が設定ファイルからアドレスを
# 計算するのに対し、こちらはアドレスが固定です。
#
# すべてバイトアドレスです。PLC 版はワード (16 ビット) 単位ですが、
# i8080 は 8 ビット CPU なのでバイト単位で扱います。
#
# ## メモリマップ (拡張 RAM: 0x0000-0xFFFF)
#
#   0x0000 - 0x0FFF : ND80Z モニタ ROM クローン + 予約  (4KB, 書き換え不可)
#   0x1000 - 0x4FFF : VM コード          (16KB, org 1000h)
#   0x5000 - 0x6FFF : mruby バイトコード (8KB)
#   0x7000 - 0x7FFF : 定数プール         (4KB)
#   ─── 通常 RAM (バンク状態に無関係) ───
#   0x8000 - 0x80FF : VM 状態           (256B)
#   0x8100 - 0x81FF : レジスタファイル   (64 × 4B = 256B)
#   0x8200 - 0x82FF : IREP テーブル      (256B)
#   0x8300 - 0x83C6 : シンボルテーブル    (198B, GETGV/SETGV 用)
#   0x83C7 - 0x83F7 : === 除外 (割り込みベクタ) ===
#   0x83F8 - 0x83FF : (free)            (8B)
#   0x8400 - 0x840F : VM 起動スタブ      (10B, SP + OUT 9C + JMP vm_start)
#   0x8410 - 0x8FFF : (空き / bank_init) (3,056B)
#   0x9000 - 0x90FF : グローバル変数      (256B, 64 スロット)
#   0x9100 - 0x91BF : フレームスタック    (192B, 16 フレーム × 12B)
#   0x91C0 - 0x92BF : メソッド表         (256B, 8 クラス × 32 メソッド)
#   0x92C0 - 0x96BF : オブジェクトプール  (1,024B, 32 オブジェクト × 32B)
#   0x96C0 - 0x9FBF : コレクションプール  (2,304B, 64 スロット × 36B)
#   0x9FC0 - 0xEFFF : (free)            (~20KB)
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

    # --- 通常 RAM 領域 (バンク状態に無関係: 0x8000-0xFFFF) ---
    RAM_BASE          = 0x8000

    VM_STATE_BASE     = 0x8000
    VM_STATE_SIZE     = 0x0100   # 256B

    REG_FILE_BASE     = 0x8100
    REG_FILE_SIZE     = 0x0100   # 256B
    MAX_REGS          = 64       # 256B / 4B = 64 スロット

    IREP_TABLE_BASE   = 0x8200
    IREP_TABLE_SIZE   = 0x0100   # 256B

    # 0x83C7-0x83F7 は ND8080 割り込みベクタのため除外

    # --- 拡張 RAM 領域 (0x0000-0x7FFF、バンク切り替えで使用) ---

    VM_CODE_ORG       = 0x1000   # VM コードの org アドレス (拡張 RAM)
    VM_CODE_SIZE      = 0x4000   # 16KB

    # 起動スタブ (通常 RAM、常にアクセス可能)
    # SP 設定 → OUT 9C, F8h (拡張 RAM 選択) → JMP vm_start
    # bank_init が事前に ROM → 拡張 RAM クローンを実行する前提。
    VM_ENTRY_POINT    = 0x8400

    BYTECODE_BASE     = 0x5000
    BYTECODE_SIZE     = 0x2000   # 8KB

    POOL_BASE         = 0x7000
    POOL_SIZE         = 0x1000   # 4KB

    # シンボルテーブル (OP_GETGV / OP_SETGV 用)
    # 各エントリ 2 バイト: グローバルスロットのアドレス (LE)
    # 0x0000 = 未対応のシンボル (メソッド名等)
    SYM_TABLE_BASE    = 0x8300
    SYM_TABLE_SIZE    = 0x00C6   # 198B (0x83C7 手前まで)
    MAX_SYMBOLS       = 99       # 198 / 2

    # グローバル変数スロット ($foo, $bar 等)
    # レジスタと同じ 4 バイト形式 (型タグ + 予約 + val_lo + val_hi)
    GLOBALS_BASE      = 0x9000
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
    FRAME_STACK_BASE  = 0x9100
    FRAME_BYTES       = 12
    MAX_FRAMES        = 16
    FRAME_STACK_SIZE  = FRAME_BYTES * MAX_FRAMES  # 192B

    # フレームフィールドのバイトオフセット
    FRAME_OFF_RETURN_PC       = 0
    FRAME_OFF_RETURN_IREP     = 2
    FRAME_OFF_RETURN_REG_BASE = 3
    FRAME_OFF_KIND            = 5
    FRAME_OFF_INDEX           = 6
    FRAME_OFF_LIMIT           = 8
    FRAME_OFF_OUTER           = 10

    # フレーム種別
    FRAME_KIND_CALL    = 0   # メソッド呼び出し / クラス本体 (OP_EXEC)
    FRAME_KIND_ITERATE = 1   # times / upto
    FRAME_KIND_EACH    = 2   # each (配列要素反復, +11 に col_slot 格納)
    # each (ハッシュ。ブロックに鍵と値を渡す。+11 に col_slot 格納)
    # **番号は PLC 版と揃えています** (MemoryLayout::FRAME_KIND_HASH_EACH)
    FRAME_KIND_HASH_EACH = 3
    FRAME_KIND_LOOP    = 4   # loop (無限ループ)
    FRAME_KIND_NEW     = 5   # Class#new → initialize 呼び出し
                              # 戻り値を R[0] に写さない (オブジェクトを保持)
    # any? / all? / none?。**番号は PLC 版と揃えています**
    # 渡す値は each と同じ (R[0] の型タグで決める)。種別が持っているのは
    # 「ブロックの値をどう使うか」だけです
    FRAME_KIND_ANY     = 6
    FRAME_KIND_ALL     = 7
    FRAME_KIND_NONE    = 8
    # Array.new(8) { |i| }。ブロックの値を要素へ書く (渡すのは添字)
    FRAME_KIND_ARRAY_FILL = 9

    # 「外側フレームなし」を表す値 (トップレベル)
    FRAME_NONE = 0xFF

    # --- メソッド表 ---
    #
    # クラス × メソッド名の 2 次元表。1 バイト/エントリ (irep 番号、0=未定義)。
    # method_table[class_number * MAX_METHODS_PER_CLASS + method_id]
    # class_number * 32 は 5 回の add a で計算 (最大 7*32=224、バイトに収まる)。
    METHOD_TABLE_BASE      = 0x91C0
    MAX_CLASSES            = 8    # 0=main + 7 ユーザークラス
    MAX_METHODS_PER_CLASS  = 32
    METHOD_TABLE_SIZE      = MAX_CLASSES * MAX_METHODS_PER_CLASS  # 128B

    # --- オブジェクトプール ---
    #
    # Class#new で確保されるオブジェクトの格納領域。
    # 各スロット 32 バイト: ヘッダ 4B + インスタンス変数 7 個 × 4B。
    # TT_OBJECT の値は slot+1 (0 は main と区別するため)。
    OBJECT_POOL_BASE    = METHOD_TABLE_BASE + METHOD_TABLE_SIZE  # 0x92C0
    MAX_OBJECTS         = 32
    OBJECT_SLOT_SIZE    = 32   # 2^5 (add a × 5 で乗算)
    OBJECT_HEADER_SIZE  = 4    # +0: class_number, +1-3: reserved
    MAX_IVARS           = 7    # (32 - 4) / 4
    OBJECT_POOL_SIZE    = MAX_OBJECTS * OBJECT_SLOT_SIZE  # 256B

    # --- コレクションプール (文字列・配列) ---
    #
    # 文字列・配列の可変長データを格納する共有プール。
    # 各スロット 36 バイト: type(1B) + count(1B) + data(34B)。
    #   文字列: data = ASCII バイト列 (最大 34 文字)
    #   配列:   data = 要素スロット × 8 (4B × 8 = 32B)
    # TT_STRING / TT_ARRAY の val_lo = slot+1 (0 は「なし」)。
    COLLECTION_POOL_BASE = OBJECT_POOL_BASE + OBJECT_POOL_SIZE  # 0x96C0
    MAX_COL_SLOTS        = 64
    COL_SLOT_SIZE        = 36    # ×36 = ×32 + ×4 で乗算
    COL_HEADER_SIZE      = 2     # +0: type, +1: count
    COL_DATA_SIZE        = COL_SLOT_SIZE - COL_HEADER_SIZE  # 34B
    COL_MAX_STRING_LEN   = COL_DATA_SIZE                    # 34
    COL_MAX_ARRAY_ELEMS  = COL_DATA_SIZE / SLOT_BYTES       # 8
    COLLECTION_POOL_SIZE = MAX_COL_SLOTS * COL_SLOT_SIZE    # 576B

    # コレクションプールのスロット型
    COL_TYPE_FREE   = 0
    COL_TYPE_STRING = 1
    COL_TYPE_ARRAY  = 2
    COL_TYPE_HASH   = 3

    # Hash ペアのバイトサイズ (key 4B + value 4B)
    HASH_PAIR_BYTES     = 2 * SLOT_BYTES                      # 8
    COL_MAX_HASH_PAIRS  = COL_DATA_SIZE / HASH_PAIR_BYTES     # 4

    # --- シンボルテーブルの種別コード ---
    #
    # 2 バイト/エントリの上位バイトで種別を判別する。
    # 上位 >= 0x80 はグローバル変数のアドレス (既存のまま)。
    SYM_KIND_USER_METHOD = 0x01   # ユーザー定義メソッド (下位 = method_id)
    SYM_KIND_CLASS       = 0x02   # クラス名 (下位 = class_number)
    SYM_KIND_IVAR        = 0x03   # インスタンス変数 (下位 = ivar_index)
    # 組み込みクラス (`Array` / `Hash`)。下位 = BUILTIN_CLASS_*
    #
    # **PLC 側とは番号が違います** (あちらは 8)。種別の空間がバックエンドごと
    # に別で、ここは 1-3 しか使っていないためです
    SYM_KIND_BUILTIN_CLASS = 0x04

    # INIT_METHOD_ID の格納アドレス
    #
    # "initialize" メソッドのユーザーメソッド ID をバイトコードツールが書き込む。
    # VM_STATE_BASE 内ではなく IREP テーブルページ末尾に配置する。
    # vm_start の VM 状態クリアで消されないようにするため。
    INIT_METHOD_ID_STORE = IREP_TABLE_BASE + 0xFE  # 0x82FE

    # トップレベル (main) のクラス番号
    CLASS_MAIN = 0

    # 組み込みクラスの番号。**PLC 側と同じ値です** (VmConstants)
    BUILTIN_CLASS_ARRAY = 1
    BUILTIN_CLASS_HASH  = 2

    # Class#new の組み込みメソッドコード
    METHOD_NEW = 28

    # 文字列・配列共通の組み込みメソッド (vm_constants.rb の番号と一致)
    METHOD_LENGTH  = 18   # length / size: 文字列長・配列長
    METHOD_CONCAT  = 20   # <<: 文字列に追記 / 配列に追加
    METHOD_EACH    = 21   # each: 配列要素を反復 (ブロック必須)
    METHOD_PUSH    = 22   # push: 配列に追加

    # i8080 固有のビルトインメソッド
    METHOD_DISPLAY = 29   # display(value): 7 セグに hex 表示
    METHOD_GETKEY  = 30   # getkey: ブロッキングキー入力 (0-15)
    METHOD_PUTS    = 31   # puts(value): ASCII 2 文字を 7 セグに表示 (スクロール)
    METHOD_SETSEG  = 32   # setseg(pos, pattern): 7 セグに任意パターンを設定
    METHOD_RAND    = 33   # rand(n): 0〜n-1 の擬似乱数を返す
    METHOD_SLICE   = 34   # [](offset, length): 文字列スライス

    # any? / all? / none?。ブロックを取る
    #
    # **PLC 側とは番号が違います。** 29-31 は i8080 だけのメソッド
    # (display / getkey / puts) が使っているためです。`[]` も同じ事情で
    # 番号が違います (PLC は 26、ここは 34)。名前から番号への対応は
    # バックエンドごとに持っているので、揃っていなくても困りません。
    METHOD_ANY_P   = 35   # any?
    METHOD_ALL_P   = 36   # all?
    METHOD_NONE_P  = 37   # none?

    # --- バンク切り替え (ND8080 拡張 RAM) ---
    PORT_9C          = 0x9C    # I/O ポート 9C
    PORT_9C_BANK_BIT = 0x08    # bit 3: 0=ROM, 1=拡張RAM
    CLONE_BUF        = 0xEF00  # ROM クローン用 256B バッファ

    # ND80Z モニタ ROM ルーチン
    KEYIN1_ADDR = 0x0616  # キー入力待ち (ブロッキング)
    KEY_ADDR    = 0x0647  # キー 1 回スキャン (ノンブロッキング, A=FF:なし)

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
    OFFSET_OBJ_SP          = 0x1B   # 1B  次の空きオブジェクトスロット番号
    OFFSET_INIT_METHOD_ID  = 0x1C   # 1B  "initialize" のメソッド ID (0=なし)
    OFFSET_POOL_BASE       = 0x1D   # 2B  現在の IREP の定数プール先頭アドレス
    OFFSET_COL_SP          = 0x1F   # 1B  次の空きコレクションスロット番号

    # IREP テーブル 1 エントリのバイト数
    #
    #   +0  バイトコード先頭     (2B)
    #   +2  バイトコード長       (2B)
    #   +4  定数プール先頭       (2B)
    #   +6  nregs               (1B)
    #   +7  subtree_size        (1B)  DFS 前順でのサブツリーサイズ (自身含む)
    #   +8  シンボルテーブル先頭  (2B)  この IREP のシンボルテーブルアドレス
    IREP_ENTRY_BYTES      = 10
    IREP_OFF_BYTECODE     = 0
    IREP_OFF_BYTECODE_LEN = 2
    IREP_OFF_POOL         = 4
    IREP_OFF_NREGS        = 6
    IREP_OFF_SUBTREE_SIZE  = 7
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
        i8080 Memory Map (ND8080 拡張 RAM: 0x0000-0xFFFF)
        ────────────────────────────────────────
        0x0000-0x0FFF  Monitor ROM clone (4KB, read-only)
        0x1000-0x4FFF  VM code          (#{VM_CODE_SIZE / 1024}KB, org 1000h)
        0x5000-0x6FFF  Bytecode         (#{BYTECODE_SIZE / 1024}KB)
        0x7000-0x7FFF  Constant pool    (#{POOL_SIZE / 1024}KB)
        0x8000-0x80FF  VM state         (#{VM_STATE_SIZE}B)
        0x8100-0x81FF  Register file    (#{MAX_REGS} × #{SLOT_BYTES}B = #{REG_FILE_SIZE}B)
        0x8200-0x82FF  IREP table       (#{IREP_TABLE_SIZE}B)
        0x8400         Startup stub     (JMP vm_start)
        0x9000-0x90FF  Global vars      (#{MAX_GLOBALS} × #{SLOT_BYTES}B = #{GLOBALS_SIZE}B)
        0x9100-0x91BF  Frame stack      (#{MAX_FRAMES} × #{FRAME_BYTES}B = #{FRAME_STACK_SIZE}B)
        0x91C0-0x92BF  Method table     (#{MAX_CLASSES} × #{MAX_METHODS_PER_CLASS} = #{METHOD_TABLE_SIZE}B)
        0x92C0-0x96BF  Object pool      (#{MAX_OBJECTS} × #{OBJECT_SLOT_SIZE}B = #{OBJECT_POOL_SIZE}B)
        0x96C0-0x9FBF  Collection pool  (#{MAX_COL_SLOTS} × #{COL_SLOT_SIZE}B = #{COLLECTION_POOL_SIZE}B)
        0xF000-0xFDFF  CPU stack        (#{STACK_SIZE}B)
        0xFFB8-0xFFF7  ND80Z monitor work
        0xFFF8-0xFFFF  7-seg display    (#{DISPLAY_SIZE}B)
      MAP
    end
  end
end
