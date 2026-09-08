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
require_relative "vm_constants"

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

    # 値スロットへの参照
    #
    # **呼ぶ側が使うのは「タグ」「値」「実数として」の 3 つだけです。**
    # どう指すかは機種が決めます。KV は 1 本の Z から、MELSEC は構造体の
    # 添字から作ります。
    #
    # 値は 32ビット整数としても単精度実数としても読めます。どちらで読むかは
    # 実行時のタグで決まるため、生成コードは両方を出しておいて IF で選びます。
    Slot = Struct.new(:tag, :value, :float, :word_ref) do
      # 値ワードを16ビット単位で指す (IEEE754 のビット列を直接書くときに使う)
      def word(offset) = word_ref.call(offset)
    end

    attr_reader :layout

    # emitter: 行を出す相手。**アドレスを Z に載せる行が要る**ため持ちます。
    # MELSEC は添字で直接指すので、その実装では行が出ません。
    def initialize(layout, emitter = nil)
      @layout = layout
      @emitter = emitter
      @slot_cache = {}
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

    # --- 値スロット ---

    # スロットの先頭アドレスを Z に載せ、その Z を指す Slot を返す
    #
    # **同じスロットを 2 度指すときは行を出しません** (key で覚えます)。
    # 命令 1 つの中で R[a] を何度も触るため、毎回 Z を組み直すと無駄が出ます。
    def slot_ref(key, index_expr, base_expr, z: nil, device: layout.device_name)
      return @slot_cache[key] if @slot_cache.key?(key)

      z ||= key == [:reg, :a] ? Z_PRIMARY : Z_SECONDARY
      @emitter.line "Z#{z} = #{index_expr} + #{base_expr}"
      @slot_cache[key] = build_slot(z, device)
    end

    # 既に Z に載っている先頭アドレスを値スロットとして扱う
    #
    # slot_ref と違い Z を計算する行は出しません。呼ぶ側が FOR の中などで
    # 自分で載せた場合に使います。
    def slot_on(z) = build_slot(z, layout.device_name)

    # Z 1 本でタグと値の両方を指す。**型サフィックスはデバイス側**に付ける
    def build_slot(z, device)
      value = VmConstants::SLOT_VALUE_OFFSET
      Slot.new("#{device}#{VmConstants::SLOT_TYPE_OFFSET}:Z#{z}",
               "#{device}#{value}.L:Z#{z}",
               "#{device}#{value}.F:Z#{z}",
               ->(offset) { "#{device}#{value + offset}:Z#{z}" })
    end

    # 命令 1 つを出し終えたら忘れる。次の命令では Z を組み直す
    def forget_slots = @slot_cache.clear

    # --- バイトコード ---

    # 現在位置を読み、PC を 1 つ進める
    #
    # 固定領域はインデックス修飾でしか指せないので、アドレスを Z に載せてから
    # 読みます。MELSEC は `VMBC[VMPC]` の 1 文で済みます。
    def read_bytecode_into(dest)
      pc = state(layout.pc_addr)
      @emitter.line "Z1 = #{pc} + #{bytecode_offset}"
      @emitter.line "#{dest} = #{fixed_indexed_base}:Z1"
      @emitter.line "#{pc} = #{pc} + 1"
    end
  end
end
