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

    # これ以下のタグが偽。Ruby で偽なのは nil と false だけ (0 も真)。
    TT_FALSY_MAX = TT_FALSE

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

    # --- VM 状態 ---
    VM_STOPPED  = 0
    VM_RUNNING  = 1
    VM_FINISHED = 2
    VM_ERROR    = 3

    # デバイスマッピングテーブル 1 エントリのワード数
    #   +0 device_type / +1 device_address / +2 access_type / +3 予備
    DEVICE_TABLE_STRIDE = 4
  end
end
