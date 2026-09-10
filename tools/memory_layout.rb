# frozen_string_literal: true

# PLC メモリ配置
#
# 設定 (faruby_default.yml / faruby.yml の memory 節) から各領域のアドレスを
# 計算します。ラダーが使用していない領域へ丸ごと移動できるよう、すべての
# アドレスは base からの相対で決まります。
#
# 領域は **実行中に変わるもの (EM)** と **変わらないもの (FM)** に分かれます。
# どちらもインスタンスごとにブロックを並べます。
#
#   可変 (EM)  base + n * instance_size
#   固定 (FM)  fixed_base + n * fixed_instance_size
#
# 可変ブロックの配置:
#
#   +0                    VM状態 (VM_STATE_WORDS)
#                         レジスタスタック      max_regs    × 4
#                         呼び出しスタック      max_frames  × 10
#                         メソッド表            max_methods × 1
#                         汎用グローバル変数    max_globals × 4
#                         配列プール            max_arrays  × (2 + max_array_len × 4)
#
# 固定ブロックの配置:
#
#   +0                    IREPテーブル          max_ireps   × 8
#                         バイトコード          max_bytecode
#                         定数プール            max_pool    × 4
#                         シンボル表            max_symbols × 4
#                         文字列定数            max_string_words
#
# バイトコード・定数プール・シンボル表は **全 irep 分をまとめた領域**です。
# irep ごとの位置は IREP テーブルに入れ、実行時にそこから引きます。
# 子 irep (メソッドの本体) を扱うために、アドレスを定数で焼き込めなくなりました。
#
# ## FM と ZF
#
# FM は ZF をバンクに分けたもので、`FRSET(n)` で切り替えます。faRuby はバンク 3 を
# 使い、スクリプトの先頭で `FRSET(3)`、末尾で `FRSET(0)` に戻します (現在のバンクを
# 読む命令が無いため、Z のような退避ができません)。
#
# **スクリプトからは FM、ホストからは ZF 絶対アドレスで触ります。** バンク 3 の
# FM0 は ZF#{FIXED_BANK_SIZE * 3} に当たります。FM のアドレスは 0-32767 なので
# 16 ビットに収まり、インデックスレジスタ Z に載せられます。
#
# アドレスは生成される vm_core.kvs に定数として焼き込まれます。設定を変えたら
# `rake vm_core` で再生成し、KV Studio に取り込み直す必要があります。

require "yaml"
require_relative "vm_constants"

module FaRuby
  # メモリ配置が不正な場合に発生
  class LayoutError < StandardError; end

  class MemoryLayout
    include VmConstants

    # VM 状態領域のワード数 (将来の追加に備えて余裕を持たせている)
    VM_STATE_WORDS = 56

    # --- 固定領域 (FM) ---
    #
    # FM は ZF をバンクに分けたもの。1 バンク 32768 ワードで、n = 0-3。
    #
    # **どのバンクを使うかは機種ごとの設定です** (`memory.fixed_bank`)。
    # KV スクリプトは `FRSET(n)` で選べるのでバンク 3 を使い、他と離して
    # おけます。**KV-X500 にはバンクを選ぶ手立てが無く、常にバンク 0 です。**
    # ホストは ZF の絶対アドレスで書くため、ここが食い違うとスクリプトは
    # 空のバンクを読み、命令が全部 0 に見えます (実機で 1 度やりました)。
    FIXED_BANK_SIZE = 32_768
    FIXED_BANK      = 3   # 既定 (KV スクリプト)

    # スクリプトから見たデバイス名 (バンク切り替え後)。既定はキーエンス
    FIXED_DEVICE_NAME = "FM"

    # ホストから見たデバイス名。バンクを跨いだ絶対アドレスで触る
    #
    # **三菱はどちらも ZR です。** バンクが無いので、スクリプトとホストで
    # 名前もアドレスも同じになります (doc/melsec.md)。
    FIXED_HOST_DEVICE = "ZF"

    # IREP テーブル 1 エントリのワード数
    #   +0 バイトコード先頭 / +1 バイトコード長 / +2 定数プール先頭
    #   +3 シンボル表先頭   / +4 nregs          / +5-7 予備
    #
    # 位置はいずれも FM の絶対アドレス。FM は 0-32767 なので Z に載せられる。
    IREP_TABLE_STRIDE  = 8
    IREP_BYTECODE      = 0
    IREP_BYTECODE_LEN  = 1
    IREP_POOL          = 2
    IREP_SYMBOLS       = 3
    IREP_NREGS         = 4
    # 最初の子 irep の番号。irep は階層ごとに並べてあり同じ親の子が連続するため、
    # OP_METHOD のオペランド (親から見た子の番号) を足せば通し番号になる
    IREP_FIRST_CHILD   = 5

    # 呼び出しフレーム 1 個のワード数
    #
    #   +0 戻り先 PC        呼び出し元へ戻る位置
    #   +1 戻り先 irep
    #   +2 戻り先レジスタ窓  呼び出し元の窓
    #   +3 自分のレジスタ窓  OP_GETUPVAR がここを見る
    #   +4 定義元フレーム    上位の変数を辿る鎖。ブロック用
    #   +5 種別             通常の呼び出しか反復か
    #   +6,+7 反復の現在値   32ビット。times / upto がブロックへ渡す値
    #   +8,+9 反復の上限     32ビット。この値まで繰り返す (含む)
    FRAME_WORDS        = 10
    FRAME_RETURN_PC    = 0
    FRAME_RETURN_IREP  = 1
    FRAME_RETURN_BASE  = 2
    FRAME_OWN_BASE     = 3
    FRAME_OUTER        = 4
    FRAME_KIND         = 5
    FRAME_INDEX        = 6
    FRAME_LIMIT        = 8

    # フレームの種別
    #
    # 【重要】並び順に意味があります。FRAME_KIND_ITERATE 以上が「反復中」で、
    # 判定を 1 比較で済ませています。並べ替えないでください。
    FRAME_KIND_CALL     = 0   # 通常のメソッド呼び出し
    FRAME_KIND_ITERATE  = 1   # 反復。ブロックに渡すのは添字 (times / upto)
    FRAME_KIND_EACH     = 2   # 反復。ブロックに渡すのは要素 (a.each)
    FRAME_KIND_HASH_EACH = 3  # 反復。ブロックに渡すのは鍵と値 (h.each)

    # 配列プール 1 スロットの見出し
    #
    #   +0 要素数
    #   +1~+3 予備
    #   +4~ 要素 (値スロット 4 ワード/要素)
    #
    # 要素をレジスタや定数プールと同じ 4 ワードにするのは、既存の値の
    # 読み書きをそのまま使えるようにするためです。3 ワードに詰めると
    # 1 要素あたり 1 ワード浮きますが、専用の読み書きが要ります。
    #
    # 全スロットが同じ容量です。可変長にすると空き管理が要り、
    # 断片化の面倒を PLC に持ち込むことになります。
    #
    # **見出しは 4 ワードです。** 要素が 4 ワードなので、見出しを 2 に
    # すると要素が 4 の倍数の位置から始まりません。KV はデバイスを
    # ワード単位で指すので気になりませんが、三菱は 4 ワードの構造体を
    # 並べた配列で指すため、境界に載らないと 1 要素ぶんずれます
    # (実機で 2 ワード手前に書かれました)。
    #
    # 同じ理由でスロットの大きさも 4 の倍数になります (4 + 12 × 4 = 52)。
    ARRAY_HEADER_WORDS = 4
    ARRAY_LENGTH       = 0

    # 「フレームが無い」を表す番号。トップレベルで定義されたブロックの定義元
    #
    # レジスタ窓はレジスタ領域の先頭になる。実在するフレーム番号
    # (0 から max_frames - 1) と重ならない値を使う。
    FRAME_NONE = 0xFFFF

    # VM 状態領域内のオフセット
    OFFSET_PC              = 0
    OFFSET_STATUS          = 1
    OFFSET_ERROR           = 2
    OFFSET_STEP_COUNT      = 3   # 32ビット (2ワード)
    OFFSET_STEPS_PER_CYCLE = 5
    OFFSET_CURRENT_OPCODE  = 6
    OFFSET_OPERAND_A       = 7
    OFFSET_OPERAND_B       = 8
    OFFSET_OPERAND_C       = 9
    OFFSET_BYTECODE_LEN    = 10
    OFFSET_NREGS           = 11
    OFFSET_NLOCALS         = 12
    OFFSET_RESET_REQ       = 13
    OFFSET_NUM_SYMBOLS     = 14
    # 32ビット合成スクラッチ (下位・上位の2ワード)
    # KV スクリプトの EM はサフィックス無しだと16ビット符号なしのため、
    # 負値や 65535 超の即値は一旦ここへ置いてから .L で読む
    OFFSET_TEMP32          = 16
    # 2つ目の32ビットスクラッチ。除算の切り下げ補正で余りを置く
    OFFSET_TEMP32_B        = 18
    OFFSET_LOOP_COUNTER    = 20  # FOR ループのカウンタ
    # インデックスレジスタ (Z) の退避先
    #
    # faRuby は Z を作業用に書き換えるため、そのままではラダーが使っている
    # Z の値を壊す。退避し復元することで、faRuby の実行前後で Z の内容が
    # 変わらないようにする。退避は1スキャンにつき1回だけで、命令ごとの
    # 負荷は増えない。
    #
    # 全インスタンスで共有する。退避・復元はインスタンスループの外側で
    # 1回だけ行うため、置き場所はインスタンス0のブロック内で足りる。
    # 他のインスタンスの同じ位置は未使用のまま残る (8ワード)。
    OFFSET_Z_SAVE          = 21

    # --- 実行中の irep (30 以降) ---
    #
    # irep が複数になったため、命令フェッチ・定数プール・シンボル表の位置は
    # 定数ではなく「実行中の irep のもの」になります。命令ごとに IREP テーブルを
    # 引くとスキャンタイムが延びるため、切り替え時にここへ写して使います。
    # 固定領域の位置 (CUR_*) は FM の絶対アドレス。可変領域の位置 (REG_BASE) は
    # ブロック先頭からのオフセットで、生成コードが Z9 を足す。
    OFFSET_CUR_IREP        = 30
    OFFSET_FRAME_SP        = 31  # 呼び出しフレームの段数 (0 = トップレベル)
    OFFSET_REG_BASE        = 32  # レジスタ窓の先頭 (ブロック内オフセット)
    OFFSET_CUR_BYTECODE    = 33
    OFFSET_CUR_POOL        = 34
    OFFSET_CUR_SYMBOLS     = 35
    OFFSET_NUM_IREPS       = 36
    # 呼び出し中の実引数の数。OP_SSEND が置き、OP_ENTER が定義と突き合わせる
    OFFSET_CALL_ARGC       = 37
    # このインスタンスの IREP テーブル先頭 (FM の絶対アドレス)
    #
    # 固定領域はインスタンスごとに位置が違い、Z9 (可変ブロックの先頭) からは
    # 割り算なしに求められないため、読み込み時にここへ書いておく。
    OFFSET_IREP_TABLE      = 38
    # 次に渡す配列スロットの番号。順に渡して返さないため、これが
    # max_arrays に達したら領域が足りない (回収は行わない)
    OFFSET_ARRAY_SP        = 39
    # ソースの文字コード (ENCODING_*)。文字数を数えるときの切れ目に使う。
    # バイト列は変換しないため、これ以外の用途は無い
    OFFSET_STR_ENCODING    = 40
    # 固定長でデバイスへ書いたときの余りを埋めるバイト (FARUBY_STR_FILL)
    OFFSET_STR_FILL        = 41
    # 文字列の作業用 4 ワード
    #
    # 中身を比べたり継ぎ足したりするときの作業場所です。**インデックス
    # レジスタではなくここを使う**のは、呼ぶ側 (OP_EQ・!=・ハッシュの鍵) で
    # Z の空きが違い、共通の手順にできないためです。FOR のループ変数は
    # デバイスでもよいので、Z はアドレスの計算 1 本だけで足ります。
    OFFSET_STR_INDEX       = 42
    OFFSET_STR_FLAG        = 43
    OFFSET_STR_TEMP        = 44
    OFFSET_STR_LIMIT       = 45
    # 借りた Z3 の退避先。OP_SETIDX は Z3 に書き込む値を載せている
    OFFSET_STR_SAVED_Z     = 46
    # 文字の切れ目を数えるときの作業用 5 ワード
    #
    # `length` は**文字数**を返します (`"あ".length` は Ruby では 1)。
    # バイト列を先頭から 1 回なめて切れ目を数えます。同じ走査で `s[i]` の
    # バイト位置も求まるので、両方をこの 5 ワードで済ませています。
    OFFSET_STR_COUNT       = 47   # 数えた文字数
    OFFSET_STR_SKIP        = 48   # Shift_JIS の後続バイトの印
    OFFSET_STR_TARGET      = 49   # 探している文字の番号 (-1 なら数えるだけ)
    OFFSET_STR_FOUND       = 50   # 見つけた文字の先頭バイト
    OFFSET_STR_FOUND_END   = 51   # その次の文字の先頭バイト

    # ラダーの FOR に渡す回数
    #
    # **KV Studio はスクリプト 1 本あたりの文字数と、対のない LABEL / CJ /
    # GOTO の数に上限があります。** 命令を増やすと 1 本に収まらなくなるため、
    # 群ごとに別のスクリプトへ分け、2 つのループをラダーへ出しました。
    #
    # ラダーの FOR は回数しか指定できず、途中で BREAK もできません。回数を
    # ここに置き、スクリプト側で決めます。**走らないインスタンスは 0 を
    # 入れて内側のループごと飛ばします。**
    #
    # Z の退避先と同じく、インスタンスループの外から読むため絶対アドレスで
    # 指します。置き場所はインスタンス 0 のブロック内で足ります。
    OFFSET_LADDER_INSTANCES = 52  # 外側 (インスタンス) の回数
    OFFSET_LADDER_STEPS     = 53  # 内側 (ステップ) の回数

    # 振り分け用のオペコード番号
    #
    # CURRENT_OPCODE の写しですが、**担当の群が実行したら空き番号で潰します。**
    # 群のスクリプトはラダーの FOR の中で順に必ず呼ばれるため、そのままだと
    # 後ろの群も自分の担当かどうかを上下 2 回比べることになります。潰して
    # おけば、どの群も上限との比較 1 回で済みます。
    #
    # CURRENT_OPCODE 自体を潰さないのは、群の中の連なりが番号を見るためと、
    # 止まったときに何の命令だったかを残すためです。
    OFFSET_DISPATCH         = 54

    # レジスタ窓の先頭をスロット単位で持つ写し
    #
    # **添字でスロットを指す機種のためのものです。** REG_BASE はワード単位
    # なので、4 で割らないと添字になりません。命令ごとに 1 回だけ割って
    # ここに置き、レジスタを触るたびの割り算を避けます。
    # KV は Z にアドレスを組み立てるので使いません。
    OFFSET_REG_SLOT         = 55

    DEFAULTS = {
      "device" => "EM", "base" => 0, "instances" => 1, "align" => 1000,
      "fixed_base" => 0, "fixed_align" => 1000, "fixed_bank" => FIXED_BANK,
      "fixed_device" => FIXED_DEVICE_NAME, "fixed_host_device" => FIXED_HOST_DEVICE,
      "max_regs" => 80, "max_bytecode" => 3000,
      "max_pool" => 150, "max_symbols" => 100, "max_globals" => 100,
      "max_ireps" => 16, "max_frames" => 16, "max_methods" => 64,
      "max_arrays" => 16, "max_array_len" => 12,
      "max_string_words" => 500,
    }.freeze

    attr_reader :device_name, :base, :instances, :instance_index, :align,
                :fixed_base, :fixed_align, :fixed_bank,
                :max_regs, :max_bytecode, :max_pool, :max_symbols, :max_globals,
                :max_ireps, :max_frames, :max_methods, :max_arrays, :max_array_len,
                :max_string_words

    # faruby_default.yml だけから作った配置 (既定の機種のもの)
    #
    # 利用者の faruby.yml を読まないため、環境によらず同じ結果になります。
    # 生成物のバイト一致検証やテストはこちらを使います。
    #
    # **配置は機種ごとに持ちます。** ここが見るのは `plc.model` の機種の欄です。
    # 別の機種の配置は Config#for_model から取ります。
    def self.default
      @default ||= begin
        path = File.expand_path("../faruby_default.yml", __dir__)
        data = (File.exist?(path) ? YAML.load_file(path) : {}) || {}
        from_config(data.dig("models", data.dig("plc", "model"), "memory") || {})
      end
    end

    # 設定ハッシュ (文字列キー) から生成する
    def self.from_config(config)
      c = DEFAULTS.merge(config.transform_keys(&:to_s).compact)
      new(
        device_name: c["device"], base: c["base"], instances: c["instances"],
        align: c["align"], max_regs: c["max_regs"], max_bytecode: c["max_bytecode"],
        max_pool: c["max_pool"], max_symbols: c["max_symbols"],
        max_globals: c["max_globals"], max_ireps: c["max_ireps"],
        max_frames: c["max_frames"], max_methods: c["max_methods"],
        max_arrays: c["max_arrays"], max_array_len: c["max_array_len"],
        max_string_words: c["max_string_words"],
        fixed_base: c["fixed_base"], fixed_align: c["fixed_align"],
        fixed_bank: c["fixed_bank"],
        fixed_device_name: c["fixed_device"], fixed_host_device: c["fixed_host_device"]
      )
    end

    def initialize(device_name: "EM", base: 0, instances: 1, instance_index: 0,
                   align: 1000, max_regs: 80, max_bytecode: 3000,
                   max_pool: 150, max_symbols: 100, max_globals: 100,
                   max_ireps: 16, max_frames: 16, max_methods: 64,
                   max_arrays: 16, max_array_len: 12, max_string_words: 500,
                   fixed_base: 0, fixed_align: 1000, fixed_bank: FIXED_BANK,
                   fixed_device_name: FIXED_DEVICE_NAME, fixed_host_device: FIXED_HOST_DEVICE)
      @device_name    = device_name
      @base           = Integer(base)
      @instances      = Integer(instances)
      @instance_index = Integer(instance_index)
      @align          = Integer(align)
      @fixed_base     = Integer(fixed_base)
      @fixed_align    = Integer(fixed_align)
      @fixed_bank     = Integer(fixed_bank)
      @fixed_device_name = fixed_device_name || FIXED_DEVICE_NAME
      @fixed_host_device = fixed_host_device || FIXED_HOST_DEVICE
      @max_regs       = Integer(max_regs)
      @max_bytecode   = Integer(max_bytecode)
      @max_pool       = Integer(max_pool)
      @max_symbols    = Integer(max_symbols)
      @max_globals    = Integer(max_globals)
      @max_ireps      = Integer(max_ireps)
      @max_frames     = Integer(max_frames)
      @max_methods    = Integer(max_methods)
      @max_arrays     = Integer(max_arrays)
      @max_array_len  = Integer(max_array_len)
      @max_string_words = Integer(max_string_words)
      validate!
    end

    # 指定インスタンスの配置を返す
    def for_instance(index)
      raise LayoutError, "インスタンス番号が範囲外です (#{index} / #{instances})" unless index.between?(0, instances - 1)

      self.class.new(
        device_name: device_name, base: base, instances: instances, instance_index: index,
        align: align, max_regs: max_regs, max_bytecode: max_bytecode,
        max_pool: max_pool, max_symbols: max_symbols, max_globals: max_globals,
        max_ireps: max_ireps, max_frames: max_frames, max_methods: max_methods,
        max_arrays: max_arrays, max_array_len: max_array_len,
        max_string_words: max_string_words,
        fixed_base: fixed_base, fixed_align: fixed_align, fixed_bank: fixed_bank,
        fixed_device_name: fixed_device_name, fixed_host_device: fixed_host_device
      )
    end

    # --- 領域の先頭アドレス ---
    #
    # 可変領域 (EM) はブロック先頭 origin から、固定領域 (FM) は fixed_origin から。

    # このインスタンスの可変ブロック先頭
    def origin = base + instance_index * instance_size

    def vm_state_base       = origin
    def reg_file_base       = vm_state_base + VM_STATE_WORDS
    def frame_stack_base    = reg_file_base + max_regs * SLOT_WORDS
    def method_table_base   = frame_stack_base + max_frames * FRAME_WORDS
    def general_global_base = method_table_base + max_methods
    def array_pool_base     = general_global_base + max_globals * SLOT_WORDS

    # 配列スロット 1 個のワード数。全スロット同じ
    def array_slot_words = ARRAY_HEADER_WORDS + max_array_len * SLOT_WORDS

    # このインスタンスの固定ブロック先頭 (FM の絶対アドレス)
    def fixed_origin = fixed_base + instance_index * fixed_instance_size

    def irep_table_base   = fixed_origin
    def bytecode_base     = irep_table_base + max_ireps * IREP_TABLE_STRIDE
    def pool_base         = bytecode_base + max_bytecode
    def device_table_base = pool_base + max_pool * SLOT_WORDS

    # 文字列定数の置き場所 (FM)
    #
    # 値スロットは 4 ワードなので文字列そのものは入りません。バイトコードと
    # 同じように領域を分け合い、値スロットには位置と長さだけを入れます。
    # **1 ワードに 2 バイト、先の文字が上位バイト**です。EM 側の並びと同じに
    # してあるので、OP_STRING はワード単位で写すだけで済みます。
    def string_pool_base = device_table_base + max_symbols * DEVICE_TABLE_STRIDE

    def string_addr(offset) = string_pool_base + offset

    # 固定ブロック先頭からのオフセット
    #
    # 固定領域はインスタンスごとに位置が違い、生成コードは Z9 から求められない
    # ため、先頭を VM 状態 (IREP_TABLE) から引いてこれを足します。
    def fixed_offset_of(addr) = addr - fixed_origin

    # 文字列 1 つの上限 (バイト)
    #
    # 配列プールのスロットを 1 つ使い、見出しを除いた残りに 2 バイトずつ
    # 詰めます。またがる形は作らないので、これを超える文字列は作れません。
    def max_string_bytes = (array_slot_words - ARRAY_HEADER_WORDS) * 2

    # スロット内の i ワード目 (文字列は値スロットではなく生のワード列)
    def string_word_addr(slot, index) = array_slot_addr(slot) + ARRAY_HEADER_WORDS + index

    # --- ホストから見た固定領域 ---
    #
    # スクリプトは FRSET でバンクを選んでから FM で触りますが、ホストには
    # バンクを選ぶ手段が無いため ZF の絶対アドレスで触ります。**どちらも
    # 同じ `fixed_bank` から出しているので、食い違いません。**
    def fixed_host_base = fixed_bank * FIXED_BANK_SIZE
    def fixed_host_addr(fm_addr) = fixed_host_base + fm_addr
    attr_reader :fixed_device_name, :fixed_host_device

    # 可変領域の合計 (パディングを含まない)
    def content_size
      VM_STATE_WORDS + max_regs * SLOT_WORDS + max_frames * FRAME_WORDS +
        max_methods + max_globals * SLOT_WORDS + max_arrays * array_slot_words
    end

    # 固定領域の合計 (パディングを含まない)
    def fixed_content_size
      max_ireps * IREP_TABLE_STRIDE + max_bytecode +
        max_pool * SLOT_WORDS + max_symbols * DEVICE_TABLE_STRIDE +
        max_string_words
    end

    # 1インスタンスが占有するワード数
    #
    # align の倍数に切り上げる。開始・終了アドレスが区切りの良い値になり、
    # 複数インスタンスの場合も各ブロックが丸い境界に載る。
    def instance_size       = round_up(content_size, align)
    def fixed_instance_size = round_up(fixed_content_size, fixed_align)

    # 切り上げによって生じた未使用ワード数
    def padding       = instance_size - content_size
    def fixed_padding = fixed_instance_size - fixed_content_size

    # 全インスタンスが占有するワード数
    def total_words       = instance_size * instances
    def fixed_total_words = fixed_instance_size * instances

    # faRuby が使用する最後のアドレス (全インスタンス)
    def last_addr       = base + total_words - 1
    def fixed_last_addr = fixed_base + fixed_total_words - 1

    # このインスタンスのブロックの最後のアドレス
    def block_last_addr = origin + instance_size - 1

    # --- VM 状態のアドレス ---

    def pc_addr              = vm_state_base + OFFSET_PC
    def status_addr          = vm_state_base + OFFSET_STATUS
    def error_addr           = vm_state_base + OFFSET_ERROR
    def step_count_addr      = vm_state_base + OFFSET_STEP_COUNT
    def steps_per_cycle_addr = vm_state_base + OFFSET_STEPS_PER_CYCLE
    def current_opcode_addr  = vm_state_base + OFFSET_CURRENT_OPCODE
    def operand_a_addr       = vm_state_base + OFFSET_OPERAND_A
    def operand_b_addr       = vm_state_base + OFFSET_OPERAND_B
    def operand_c_addr       = vm_state_base + OFFSET_OPERAND_C
    def bytecode_len_addr    = vm_state_base + OFFSET_BYTECODE_LEN
    def nregs_addr           = vm_state_base + OFFSET_NREGS
    def nlocals_addr         = vm_state_base + OFFSET_NLOCALS
    def reset_req_addr       = vm_state_base + OFFSET_RESET_REQ
    def num_symbols_addr     = vm_state_base + OFFSET_NUM_SYMBOLS
    def temp32_addr          = vm_state_base + OFFSET_TEMP32
    def temp32_b_addr        = vm_state_base + OFFSET_TEMP32_B
    def loop_counter_addr    = vm_state_base + OFFSET_LOOP_COUNTER
    def cur_irep_addr        = vm_state_base + OFFSET_CUR_IREP
    def frame_sp_addr        = vm_state_base + OFFSET_FRAME_SP
    def reg_base_addr        = vm_state_base + OFFSET_REG_BASE
    def cur_bytecode_addr    = vm_state_base + OFFSET_CUR_BYTECODE
    def cur_pool_addr        = vm_state_base + OFFSET_CUR_POOL
    def cur_symbols_addr     = vm_state_base + OFFSET_CUR_SYMBOLS
    def num_ireps_addr       = vm_state_base + OFFSET_NUM_IREPS
    def call_argc_addr       = vm_state_base + OFFSET_CALL_ARGC
    def irep_table_addr_addr = vm_state_base + OFFSET_IREP_TABLE
    def array_sp_addr        = vm_state_base + OFFSET_ARRAY_SP
    def str_encoding_addr    = vm_state_base + OFFSET_STR_ENCODING
    def str_fill_addr        = vm_state_base + OFFSET_STR_FILL
    def str_index_addr       = vm_state_base + OFFSET_STR_INDEX
    def str_flag_addr        = vm_state_base + OFFSET_STR_FLAG
    def str_temp_addr        = vm_state_base + OFFSET_STR_TEMP
    def str_limit_addr       = vm_state_base + OFFSET_STR_LIMIT
    def str_saved_z_addr     = vm_state_base + OFFSET_STR_SAVED_Z
    def str_count_addr       = vm_state_base + OFFSET_STR_COUNT
    def str_skip_addr        = vm_state_base + OFFSET_STR_SKIP
    def str_target_addr      = vm_state_base + OFFSET_STR_TARGET
    def str_found_addr       = vm_state_base + OFFSET_STR_FOUND
    def str_found_end_addr   = vm_state_base + OFFSET_STR_FOUND_END
    def reg_slot_base_addr   = vm_state_base + OFFSET_REG_SLOT

    # Z レジスタ n (1始まり) の退避先アドレス
    #
    # 全インスタンスで共有するため、インスタンス番号によらず同じ場所を返す。
    def z_save_addr(index) = base + OFFSET_Z_SAVE + (index - 1)

    # ラダーの FOR に渡す回数の置き場所
    #
    # Z の退避先と同じく全インスタンスで共有するため、絶対アドレスを返す。
    def ladder_instances_addr = base + OFFSET_LADDER_INSTANCES
    def ladder_steps_addr     = base + OFFSET_LADDER_STEPS

    # 振り分け用のオペコード番号 (インスタンスごと)
    def dispatch_addr = vm_state_base + OFFSET_DISPATCH

    # --- ブロック内オフセット ---

    # 絶対アドレスをブロック先頭からのオフセットに変換する
    #
    # 生成される KV スクリプトはブロック先頭を Z レジスタに載せ、
    # ここで得たオフセットをインデックス修飾で足します (EM7:Z9)。
    # インスタンスによらず同じコードが使えるのはこのためです。
    def offset_of(addr) = addr - origin

    # 最後のインスタンスのブロック先頭
    def last_origin = base + (instances - 1) * instance_size

    # --- 値スロットのアドレス ---

    def reg_slot_addr(index)  = reg_file_base + index * SLOT_WORDS
    def reg_addr(index)       = reg_slot_addr(index) + SLOT_VALUE_OFFSET
    def reg_type_addr(index)  = reg_slot_addr(index) + SLOT_TYPE_OFFSET

    def pool_slot_addr(index) = pool_base + index * SLOT_WORDS
    def pool_addr(index)      = pool_slot_addr(index) + SLOT_VALUE_OFFSET
    def pool_type_addr(index) = pool_slot_addr(index) + SLOT_TYPE_OFFSET

    def bytecode_addr(offset) = bytecode_base + offset

    def device_table_addr(index) = device_table_base + index * DEVICE_TABLE_STRIDE

    def irep_table_addr(index) = irep_table_base + index * IREP_TABLE_STRIDE
    def frame_addr(index)      = frame_stack_base + index * FRAME_WORDS

    # ユーザー定義メソッド ID => 本体の irep 番号 (0 = 未定義)
    def method_table_addr(id)  = method_table_base + id

    # 汎用グローバル変数。デバイスマッピングテーブルには「値ワード」の
    # アドレスを格納するため、GETGV/SETGV の EM デバイス経路をそのまま流用できる
    def general_global_slot_addr(index) = general_global_base + index * SLOT_WORDS
    def general_global_addr(index)      = general_global_slot_addr(index) + SLOT_VALUE_OFFSET

    # 配列プール。スロット番号から見出しの先頭を求める
    def array_slot_addr(index) = array_pool_base + index * array_slot_words

    # スロット内の要素 (値スロット) の先頭
    def array_element_addr(index, element)
      array_slot_addr(index) + ARRAY_HEADER_WORDS + element * SLOT_WORDS
    end

    # --- デバイス文字列 ---

    def device(addr)      = "#{device_name}#{addr}"
    def device_long(addr) = "#{device_name}#{addr}.L"

    # 固定領域はスクリプトからは FM で触る (FRSET でバンクを選んだ後)
    def fixed_device(addr)      = "#{fixed_device_name}#{addr}"
    def fixed_device_long(addr) = "#{fixed_device_name}#{addr}.L"

    # --- 表示用 ---

    # 可変領域 (EM) の一覧を [名前, 開始, 終了, ワード数] の配列で返す
    def regions
      list = [
        ["VM状態",            vm_state_base,       reg_file_base - 1],
        ["レジスタスタック",  reg_file_base,       frame_stack_base - 1],
        ["呼び出しスタック",  frame_stack_base,    method_table_base - 1],
        ["メソッド表",        method_table_base,   general_global_base - 1],
        ["汎用グローバル変数", general_global_base, array_pool_base - 1],
        ["配列プール",        array_pool_base,     array_pool_base + max_arrays * array_slot_words - 1],
      ]
      list << ["予備 (端数調整)", origin + content_size, origin + instance_size - 1] if padding.positive?
      list.map { |name, from, to| [name, from, to, to - from + 1] }
    end

    # 固定領域 (FM) の一覧。アドレスは FM のもの
    def fixed_regions
      list = [
        ["IREPテーブル", irep_table_base,   bytecode_base - 1],
        ["バイトコード", bytecode_base,     pool_base - 1],
        ["定数プール",   pool_base,         device_table_base - 1],
        ["シンボル表",   device_table_base, device_table_base + max_symbols * DEVICE_TABLE_STRIDE - 1],
      ]
      if fixed_padding.positive?
        list << ["予備 (端数調整)", fixed_origin + fixed_content_size,
                 fixed_origin + fixed_instance_size - 1]
      end
      list.map { |name, from, to| [name, from, to, to - from + 1] }
    end

    def to_s
      "#{device_name}#{base}-#{device_name}#{last_addr} / " \
        "#{fixed_device_name}#{fixed_base}-#{fixed_device_name}#{fixed_last_addr} " \
        "(#{instances}インスタンス × #{instance_size}+#{fixed_instance_size}ワード)"
    end

    private

    def round_up(size, unit)
      return size if unit <= 1

      ((size + unit - 1) / unit) * unit
    end

    def validate!
      raise LayoutError, "base は 0 以上にしてください (#{@base})" if @base.negative?
      raise LayoutError, "fixed_base は 0 以上にしてください (#{@fixed_base})" if @fixed_base.negative?
      raise LayoutError, "instances は 1 以上にしてください (#{@instances})" if @instances < 1

      { "max_regs" => @max_regs, "max_bytecode" => @max_bytecode, "max_pool" => @max_pool,
        "max_symbols" => @max_symbols, "max_globals" => @max_globals,
        "max_ireps" => @max_ireps, "max_frames" => @max_frames,
        "max_methods" => @max_methods, "max_arrays" => @max_arrays,
        "max_array_len" => @max_array_len }.each do |name, value|
        raise LayoutError, "#{name} は 1 以上にしてください (#{value})" if value < 1
      end

      return if fixed_last_addr < FIXED_BANK_SIZE

      raise LayoutError, "固定領域がバンクに収まりません " \
                         "(#{fixed_device_name}#{fixed_last_addr} > #{FIXED_BANK_SIZE - 1})"
    end
  end
end
