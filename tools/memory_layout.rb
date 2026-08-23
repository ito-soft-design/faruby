# frozen_string_literal: true

# PLC メモリ配置
#
# 設定 (faruby_default.yml / faruby.yml の memory 節) から各領域のアドレスを
# 計算します。ラダーが使用していない領域へ丸ごと移動できるよう、すべての
# アドレスは base からの相対で決まります。
#
# 1インスタンス分のブロックを instances 個並べた配置になります。
#
#   base + 0 * instance_size   インスタンス0
#   base + 1 * instance_size   インスタンス1
#
# ブロック内の配置 (サイズ設定から詰めて計算):
#
#   +0                    VM状態 (VM_STATE_WORDS)
#   +32                   レジスタファイル      max_regs   × 4
#                         バイトコード          max_bytecode
#                         定数プール            max_pool    × 4
#                         デバイステーブル      max_symbols × 4
#                         汎用グローバル変数    max_globals × 4
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
    VM_STATE_WORDS = 32

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

    DEFAULTS = {
      "device" => "EM", "base" => 0, "instances" => 1, "align" => 1000,
      "max_regs" => 80, "max_bytecode" => 3000,
      "max_pool" => 200, "max_symbols" => 100, "max_globals" => 100,
    }.freeze

    attr_reader :device_name, :base, :instances, :instance_index, :align,
                :max_regs, :max_bytecode, :max_pool, :max_symbols, :max_globals

    # faruby_default.yml だけから作った配置
    #
    # 利用者の faruby.yml を読まないため、環境によらず同じ結果になります。
    # vm_core.kvs のバイト一致検証やテストはこちらを使います。
    def self.default
      @default ||= begin
        path = File.expand_path("../faruby_default.yml", __dir__)
        from_config((File.exist?(path) ? YAML.load_file(path) : {})&.fetch("memory", nil) || {})
      end
    end

    # 設定ハッシュ (文字列キー) から生成する
    def self.from_config(config)
      c = DEFAULTS.merge(config.transform_keys(&:to_s).compact)
      new(
        device_name: c["device"], base: c["base"], instances: c["instances"],
        align: c["align"], max_regs: c["max_regs"], max_bytecode: c["max_bytecode"],
        max_pool: c["max_pool"], max_symbols: c["max_symbols"],
        max_globals: c["max_globals"]
      )
    end

    def initialize(device_name: "EM", base: 0, instances: 1, instance_index: 0,
                   align: 1000, max_regs: 80, max_bytecode: 3000,
                   max_pool: 200, max_symbols: 100, max_globals: 100)
      @device_name    = device_name
      @base           = Integer(base)
      @instances      = Integer(instances)
      @instance_index = Integer(instance_index)
      @align          = Integer(align)
      @max_regs       = Integer(max_regs)
      @max_bytecode   = Integer(max_bytecode)
      @max_pool       = Integer(max_pool)
      @max_symbols    = Integer(max_symbols)
      @max_globals    = Integer(max_globals)
      validate!
    end

    # 指定インスタンスの配置を返す
    def for_instance(index)
      raise LayoutError, "インスタンス番号が範囲外です (#{index} / #{instances})" unless index.between?(0, instances - 1)

      self.class.new(
        device_name: device_name, base: base, instances: instances, instance_index: index,
        align: align, max_regs: max_regs, max_bytecode: max_bytecode,
        max_pool: max_pool, max_symbols: max_symbols, max_globals: max_globals
      )
    end

    # --- 領域の先頭アドレス ---

    # このインスタンスのブロック先頭
    def origin = base + instance_index * instance_size

    def vm_state_base       = origin
    def reg_file_base       = vm_state_base + VM_STATE_WORDS
    def bytecode_base       = reg_file_base + max_regs * SLOT_WORDS
    def pool_base           = bytecode_base + max_bytecode
    def device_table_base   = pool_base + max_pool * SLOT_WORDS
    def general_global_base = device_table_base + max_symbols * DEVICE_TABLE_STRIDE

    # 各領域の合計 (パディングを含まない)
    def content_size
      VM_STATE_WORDS + max_regs * SLOT_WORDS + max_bytecode +
        max_pool * SLOT_WORDS + max_symbols * DEVICE_TABLE_STRIDE +
        max_globals * SLOT_WORDS
    end

    # 1インスタンスが占有するワード数
    #
    # align の倍数に切り上げる。開始・終了アドレスが区切りの良い値になり、
    # 複数インスタンスの場合も各ブロックが丸い境界に載る。
    def instance_size
      return content_size if align <= 1

      ((content_size + align - 1) / align) * align
    end

    # 切り上げによって生じた未使用ワード数
    def padding = instance_size - content_size

    # 全インスタンスが占有するワード数
    def total_words = instance_size * instances

    # faRuby が使用する最後のアドレス (全インスタンス)
    def last_addr = base + total_words - 1

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
    def loop_counter_addr    = vm_state_base + OFFSET_LOOP_COUNTER

    # Z レジスタ n (1始まり) の退避先アドレス
    #
    # 全インスタンスで共有するため、インスタンス番号によらず同じ場所を返す。
    def z_save_addr(index) = base + OFFSET_Z_SAVE + (index - 1)

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

    # 汎用グローバル変数。デバイスマッピングテーブルには「値ワード」の
    # アドレスを格納するため、GETGV/SETGV の EM デバイス経路をそのまま流用できる
    def general_global_slot_addr(index) = general_global_base + index * SLOT_WORDS
    def general_global_addr(index)      = general_global_slot_addr(index) + SLOT_VALUE_OFFSET

    # --- デバイス文字列 ---

    def device(addr)      = "#{device_name}#{addr}"
    def device_long(addr) = "#{device_name}#{addr}.L"

    # --- 表示用 ---

    # 領域の一覧を [名前, 開始, 終了, ワード数] の配列で返す
    def regions
      list = [
        ["VM状態",            vm_state_base,       reg_file_base - 1],
        ["レジスタファイル",  reg_file_base,       bytecode_base - 1],
        ["バイトコード",      bytecode_base,       pool_base - 1],
        ["定数プール",        pool_base,           device_table_base - 1],
        ["デバイステーブル",  device_table_base,   general_global_base - 1],
        ["汎用グローバル変数", general_global_base, general_global_base + max_globals * SLOT_WORDS - 1],
      ]
      list << ["予備 (端数調整)", origin + content_size, origin + instance_size - 1] if padding.positive?
      list.map { |name, from, to| [name, from, to, to - from + 1] }
    end

    def to_s
      "#{device_name}#{base}-#{device_name}#{last_addr} " \
        "(#{instances}インスタンス × #{instance_size}ワード)"
    end

    private

    def validate!
      raise LayoutError, "base は 0 以上にしてください (#{@base})" if @base.negative?
      raise LayoutError, "instances は 1 以上にしてください (#{@instances})" if @instances < 1

      { "max_regs" => @max_regs, "max_bytecode" => @max_bytecode, "max_pool" => @max_pool,
        "max_symbols" => @max_symbols, "max_globals" => @max_globals }.each do |name, value|
        raise LayoutError, "#{name} は 1 以上にしてください (#{value})" if value < 1
      end
    end
  end
end
