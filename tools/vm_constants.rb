# frozen_string_literal: true

# VM の定数
#
# メモリ配置に依存しない値だけをここに置きます。
# アドレスは設定によって変わるため MemoryLayout が扱います。

module FaRuby
  module VmConstants
    # --- 値スロット ---
    #
    # レジスタ・定数プール・汎用グローバル変数は共通の「値スロット」形式で
    # 格納します。1 スロット = 4 ワード。
    #
    #   +0 : 型タグ (TT_*)          .U でアクセス
    #   +1 : 値 下位ワード          ┐ .L でアクセス (+1 が起点)
    #   +2 : 値 上位ワード          ┘
    #   +3 : 予備 (将来の拡張用)
    #
    # 生成コードはスロット先頭を Z に載せ、タグを EM0:Z、値を EM1.L:Z で
    # 指します。1 本の Z で両方を扱えるようにするためです。
    SLOT_WORDS        = 4
    SLOT_TYPE_OFFSET  = 0
    SLOT_VALUE_OFFSET = 1

    # --- 値の型タグ ---
    #
    # .mrb バイナリには実行時の型情報が含まれないため、本プロジェクトで
    # 定義した番号です (mruby/c の mrbc_vtype に倣った命名)。
    # TT_EMPTY = 0 はレジスタクリア直後の状態と一致します。
    #
    # 【重要】この並び順には意味があります。Ruby で偽になるのは nil と false
    # だけなので、偽の 2 つを真より小さい番号に置いてあります。真偽判定が
    # 「タグ >= TT_TRUE」の1比較で済みます。並べ替えないでください。
    TT_EMPTY   = 0     # 未初期化 (nil と同じく偽として扱う)
    TT_NIL     = 1
    TT_FALSE   = 2
    TT_TRUE    = 3
    TT_INTEGER = 4
    TT_FLOAT   = 5
    TT_SYMBOL  = 6
    TT_STRING  = 7     # 以降は未実装 (領域予約のみ)
    TT_ARRAY   = 8
    TT_HASH    = 9
    TT_OBJECT  = 10
    TT_DEVICE  = 11    # デバイス族への参照 ($DM など)
    TT_PROC    = 12    # メソッドの本体への参照。値は irep 番号

    # --- デバイス参照 (TT_DEVICE) の表現 ---
    #
    # `$DM[100 + i]` のように実行時に決まるアドレスへアクセスするための値です。
    # `$DM` を読むとこの型の値になり、添字を付けると実際の読み書きになります。
    #
    #   値 下位ワード : ベースアドレス (裸の $DM なら 0)
    #   値 上位ワード : デバイス種別 + アクセス幅 * DEVICE_REF_ACCESS_SCALE
    #
    # 種別と幅を1ワードに詰めるのは、スロットの予備ワードを使うと OP_MOVE が
    # 4 ワード目まで複製する必要が出て、複製のたびに費用がかかるためです。
    # 種別は 0-9、幅は 0-4 なので 16 倍で分離できます。
    DEVICE_REF_ACCESS_SCALE = 16

    # これ以下のタグが偽。Ruby で偽なのは nil と false だけ (0 も真)。
    TT_FALSY_MAX = TT_FALSE

    # --- 単精度実数 (IEEE754) の特殊値 ---
    #
    # Ruby の 1.0 / 0 は Infinity で例外にならないが、KV スクリプトで
    # 0 除算を実行すると軽度エラー CR2012 が出る。そのため除数が 0 のときは
    # 除算を実行せず、ビット列を直接書き込む。下位ワードはいずれも 0。
    FLOAT_POS_INF_HI = 0x7F80   # +Infinity (0x7F800000)
    FLOAT_NEG_INF_HI = 0xFF80   # -Infinity (0xFF800000)
    FLOAT_NAN_HI     = 0x7FC0   # NaN       (0x7FC00000)

    # 値を持たない型の値ワード
    #
    # true を 1、false と nil を 0 にしてあるのは、ビットデバイスへの書き込みを
    # 値だけで判定できるようにするためです ($MR10 = true も $MR10 = 1 も ON)。
    TT_CANONICAL_VALUE = {
      TT_EMPTY  => 0,
      TT_NIL    => 0,
      TT_FALSE  => 0,
      TT_TRUE   => 1,
      TT_OBJECT => 0,   # トップレベルの self (main)
    }.freeze

    # --- デバイスタイプ ---
    DEVICE_TYPE_EM = 0
    DEVICE_TYPE_DM = 1
    DEVICE_TYPE_ZF = 2
    DEVICE_TYPE_R  = 3
    DEVICE_TYPE_MR = 4
    DEVICE_TYPE_B  = 5
    DEVICE_TYPE_L  = 6
    DEVICE_TYPE_CR = 7   # インデックス修飾不可のため非対応
    DEVICE_TYPE_T  = 8
    DEVICE_TYPE_C  = 9

    # --- ワードデバイスのアクセス幅 ---
    #
    #   $DM100   → ACCESS_S  (.S)  16ビット符号付き ※既定
    #   $DM100U  → ACCESS_U  (.U)  16ビット符号なし
    #   $DM100L  → ACCESS_L  (.L)  32ビット符号付き
    #   $DM100D  → ACCESS_D  (.D)  32ビット符号なし
    #   $DM100F  → ACCESS_F  (.F)  単精度実数 (未実装)
    ACCESS_S = 0
    ACCESS_U = 1
    ACCESS_L = 2
    ACCESS_D = 3
    ACCESS_F = 4

    # 個別ビット。ビットデバイスをサフィックス無しで書いたとき
    #
    # 0 (ACCESS_S) と区別する必要があります。ビットデバイスに幅を付けると
    # 整数として扱われるため、「幅の指定が無い」ことを表す値が要ります。
    ACCESS_BIT = 5

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
      ACCESS_F => "実数", ACCESS_BIT => "ビット",
    }.freeze

    # --- VM 状態 ---
    VM_STOPPED  = 0
    VM_RUNNING  = 1
    VM_FINISHED = 2
    VM_ERROR    = 3

    # デバイスマッピングテーブル 1 エントリのワード数
    #
    # シンボル 1 つにつき 1 エントリで、+3 の種別によって意味が変わります。
    #
    #   種別 0 (値)         +0 device_type / +1 device_address / +2 access_type
    #   種別 1 (デバイス族) 同上。アドレスを持たず、添字で決める
    #   種別 2 (メソッド)   +0 METHOD_* / +1 ユーザー定義メソッドID / +2 引数の数
    DEVICE_TABLE_STRIDE = 4
    DEVICE_TABLE_KIND_OFFSET = 3

    # シンボルの種別
    #
    # `$` で始まるシンボルはグローバル変数 (デバイスか汎用グローバル)、
    # それ以外はメソッド名です。同じシンボル表を OP_GETGV / OP_SETGV と
    # OP_SEND が共有するため、種別で振り分けます。
    SYMBOL_KIND_VALUE  = 0
    SYMBOL_KIND_FAMILY = 1
    SYMBOL_KIND_METHOD = 2

    # --- 組み込みメソッド ---
    #
    # メソッド名はホスト側で番号に解決してテーブルに載せます。VM は文字列を
    # 持たず、整数の分岐だけで振り分けます。
    #
    # 【重要】並び順に意味があります。METHOD_NUMERIC_MIN 以上はレシーバが
    # 数値でなければならず、判定を 1 比較で済ませています。並べ替えないでください。
    METHOD_NONE  = 0   # 未対応 (実行時エラー)
    METHOD_NE    = 1   # !=
    METHOD_NOT   = 2   # !
    METHOD_MOD   = 3   # %
    METHOD_ABS   = 4
    METHOD_TO_I  = 5
    METHOD_TO_F  = 6
    METHOD_FLOOR = 7
    METHOD_ROUND = 8
    METHOD_TIMES = 9    # ブロックを取る
    METHOD_UPTO  = 10   # ブロックを取る

    # これ以上のメソッドはレシーバが数値であること
    METHOD_NUMERIC_MIN = METHOD_MOD

    # これ以上のメソッドはブロックを取る (OP_SENDB でしか呼べない)
    #
    # 並びに意味があるのは真偽判定のタグ順と同じ理由です。1 比較で振り分けます。
    METHOD_BLOCK_MIN = METHOD_TIMES

    # メソッド名 => [番号, 引数の数]
    BUILTIN_METHODS = {
      "!="    => [METHOD_NE,    1],
      "!"     => [METHOD_NOT,   0],
      "%"     => [METHOD_MOD,   1],
      "abs"   => [METHOD_ABS,   0],
      "to_i"  => [METHOD_TO_I,  0],
      "to_f"  => [METHOD_TO_F,  0],
      "floor" => [METHOD_FLOOR, 0],
      "round" => [METHOD_ROUND, 0],
      "times" => [METHOD_TIMES, 0],
      "upto"  => [METHOD_UPTO,  1],
    }.freeze

    METHOD_NAMES = BUILTIN_METHODS.to_h { |name, (code, _argc)| [code, name] }.freeze

    # ブロックを取らないメソッド。OP_SEND / OP_SSEND の振り分けはこれだけを並べる
    BUILTIN_PLAIN_METHODS =
      METHOD_NAMES.reject { |code, _| code >= METHOD_BLOCK_MIN }.freeze

    # --- ユーザー定義メソッド ---
    #
    # 組み込みに無い名前にはホスト側で 1 から通し番号を振ります。シンボル表は
    # irep ごとに別なので、同じ名前が複数のエントリに現れます。番号を挟むことで
    # どのエントリから呼んでも同じメソッドに行き着きます。
    #
    # `OP_DEF` が「メソッド表[番号] = irep 番号」を書き、`OP_SSEND` が引きます。
    # 0 は「ユーザー定義メソッドではない」印なので、番号は 1 から始めます。
    METHOD_ID_NONE = 0

    # メソッド表に入っている irep 番号 0 は「まだ定義されていない」を表します。
    # irep 0 はトップレベルでメソッドの本体にはならないため、印として使えます。
    METHOD_UNDEFINED = 0

    # OP_ENTER のオペランド (aspec) から必須引数の数を取り出すシフト量
    #
    #   引数 1 個 → 0x040000 (262144)
    #   引数 2 個 → 0x080000 (524288)
    #
    # 残りのビットが立っていれば省略可能引数・可変長・キーワードのいずれかで、
    # faRuby はいずれも未対応です。
    ASPEC_REQ_SHIFT = 18
  end
end
