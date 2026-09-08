# frozen_string_literal: true

# デバイスの指し方
#
# **命令の意味と算法は機種によらず同じで、違うのはデバイスをどう指すかです。**
# 生成器 (KvsEmitter) は 2,600 行ありますが、そのほとんどは型の区分・エラー
# コード・文字列の扱いといった算法で、機種を増やしても変わりません。変わるのは
# ここに集めた十数個です。
#
# 三菱版をバックエンドごと別に書く道もありましたが、**算法をもう一組持つ**
# ことになります。`OP_SSEND` が `OP_SEND` の振り分けを重複して持っているせいで
# 起きた問題と同じものを、自分から作ることになるため採りませんでした。
#
# ## 機種による違い
#
#   KV      Z1 = EM7:Z9 * 4 + EM32:Z9 + Z9      アドレスを Z に組み立てて
#           EM1.L:Z1 = EM1.L:Z2                 修飾で指す
#
#   MELSEC  VMRV[VMOPA] := VMRV[VMOPB];         型付きラベル配列の添字
#
# KV は 1 本の Z でタグと値の両方を指し、MELSEC は配列を型ごとに分けます。
# **アドレス計算そのものが要らなくなる**ので、綴り替えでは届きません。

require_relative "memory_layout"

module FaRuby
  # KV スクリプト / ST (KV-5000・KV-X500) のデバイスの指し方
  #
  # ブロック先頭は Z9 に載っています。ブロック内の固定位置はオフセットを
  # インデックス修飾で足して指します (`EM7:Z9`)。こうすることで、どの
  # インスタンスでも同じコードが動きます。
  #
  # **型サフィックスはデバイス側に付けます** (`EM16.L:Z9`)。`EM16:Z9.L` と
  # 書くと `.L` がインデックスレジスタに結合し、エラーにならないまま
  # 16 ビットアクセスに退化します (実機で 91 箇所やりました)。
  class KvDevices
    # インデックスレジスタの割り当て
    # Z1 = 主オペランド (通常は代入先の R[a])、Z2 = 副オペランド
    # Z3-Z8 はバイトコードフェッチとデバイステーブル参照が使う
    # Z9 = 実行中インスタンスのブロック先頭
    Z_PRIMARY = 1
    Z_SECONDARY = 2
    Z_INSTANCE = 9
    # OP_SETIDX の代入元。Z1 は参照、Z2 は添字が使うので3本目を割り当てる
    Z_VALUE = 3

    # faRuby が書き換える Z レジスタ
    #
    # PLC の Z はラダーと共有する資源なので、スクリプトの先頭で退避し
    # 末尾で復元します。Z11 / Z12 は特別な用途があり使用できません
    # (実機で確認済み)。使えるのは Z1-Z10 で、faRuby は Z1-Z9 を使います。
    USED_Z = (1..9).to_a.freeze

    attr_reader :layout

    def initialize(layout)
      @layout = layout
    end

    # --- インデックス修飾の基点 ---

    # 例: "EM0"。デバイス番号 0 からの相対を Z で指定する書き方に使う。
    # PC を指す layout.pc_addr とは別物なので混同しないこと
    def indexed_base = "#{layout.device_name}0"

    # 固定領域 (FM) をインデックス修飾で指すときの基点
    #
    # FM は ZF をバンクに分けたもの。スクリプトの先頭で FRSET でバンクを
    # 選んであるため、ここではバンクを意識せず 0-32767 のアドレスで指せる
    def fixed_indexed_base = "#{layout.fixed_device_name}0"

    # --- インスタンス相対のデバイス参照 ---

    # ブロック内の固定位置を指す (16ビット)
    def state(addr) = "#{layout.device_name}#{layout.offset_of(addr)}:Z#{Z_INSTANCE}"

    # ブロック内の固定位置を指す (32ビット)
    def state_long(addr) = "#{layout.device_name}#{layout.offset_of(addr)}.L:Z#{Z_INSTANCE}"

    # Z に絶対アドレスを組み立てる式の末尾に足す項
    def block_offset(base) = "#{layout.offset_of(base)} + Z#{Z_INSTANCE}"

    # 実行中の irep の領域を指す項
    #
    # irep が複数になったため、バイトコード・定数プール・シンボル表の位置は
    # 定数ではありません。切り替え時に VM 状態へ写した値を使います。
    #
    # 固定領域 (FM) の位置は **絶対アドレス**で持ちます。FM は 0-32767 なので
    # Z に載り、インスタンスごとの先頭を足す必要がありません。
    # 可変領域 (EM) はブロック先頭からのオフセットなので Z9 を足します。
    def bytecode_offset   = state(layout.cur_bytecode_addr)
    def pool_offset       = state(layout.cur_pool_addr)
    def symbols_offset    = state(layout.cur_symbols_addr)
    def irep_table_offset = state(layout.irep_table_addr_addr)

    # 固定領域の位置。インスタンスごとに違うため先頭からの相対で組み立てる
    def fixed_offset(base) = "#{irep_table_offset} + #{layout.fixed_offset_of(base)}"

    def reg_offset = "#{state(layout.reg_base_addr)} + Z#{Z_INSTANCE}"

    # Z の退避先。インスタンスループの外で 1 回だけ触るので絶対アドレス
    def z_save(z) = layout.device(layout.z_save_addr(z))
  end
end
