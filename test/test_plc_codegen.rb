# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/memory_map"
require_relative "../tools/mrb_parser"
require_relative "../tools/plc_codegen"
require_relative "../simulator/em_memory"

# PlcCodegen のユニットテスト
# 値スロット (4ワード = 型タグ + 32ビット値 + 予備) のレイアウトを検証します。
class TestPlcCodegen < Minitest::Test
  include FaRuby::MemoryMap

  # 合成 IREP を組み立てるヘルパー
  def build_irep(nregs: 3, nlocals: 2, pool: [], symbols: [], instructions: "\x69")
    irep = FaRuby::Irep.new
    irep.nregs = nregs
    irep.nlocals = nlocals
    irep.instructions = instructions
    irep.ilen = instructions.bytesize
    pool.each { |type, value| irep.add_pool_entry(FaRuby::PoolEntry.new(type, value)) }
    symbols.each { |s| irep.add_symbol(s) }
    irep
  end

  # memory_image を EmMemory にロードして返す
  def load_image(irep)
    image = FaRuby::PlcCodegen.new(irep).memory_image
    em = FaRuby::EmMemory.new
    em.load_image(image)
    [em, image]
  end

  # === 定数プール ===

  def test_pool_slot_layout
    irep = build_irep(pool: [[:int32, 123456], [:int32, 7]])
    em, = load_image(irep)

    assert_equal TT_INTEGER, em.read_u16(FaRuby::MemoryMap.pool_type_addr(0))
    assert_equal 123456, em.read_s32(FaRuby::MemoryMap.pool_addr(0))
    assert_equal TT_INTEGER, em.read_u16(FaRuby::MemoryMap.pool_type_addr(1))
    assert_equal 7, em.read_s32(FaRuby::MemoryMap.pool_addr(1))
  end

  # 32ビット値がスロット境界をまたいで隣のエントリを壊さないこと
  def test_pool_slots_do_not_overlap
    irep = build_irep(pool: [[:int32, -1], [:int32, 42]])
    em, = load_image(irep)

    assert_equal(-1, em.read_s32(FaRuby::MemoryMap.pool_addr(0)))
    assert_equal 42, em.read_s32(FaRuby::MemoryMap.pool_addr(1))
    assert_equal TT_INTEGER, em.read_u16(FaRuby::MemoryMap.pool_type_addr(1))
  end

  def test_pool_stride_is_slot_words
    assert_equal SLOT_WORDS,
                 FaRuby::MemoryMap.pool_slot_addr(1) - FaRuby::MemoryMap.pool_slot_addr(0)
    assert_equal FaRuby::MemoryMap.pool_slot_addr(0) + SLOT_VALUE_OFFSET,
                 FaRuby::MemoryMap.pool_addr(0)
  end

  # int64 は下位32ビットのみ使用する (従来の挙動を維持)
  def test_pool_int64_truncated_to_32bit
    irep = build_irep(pool: [[:int64, 0x1_0000_0007]])
    em, = load_image(irep)

    assert_equal TT_INTEGER, em.read_u16(FaRuby::MemoryMap.pool_type_addr(0))
    assert_equal 7, em.read_s32(FaRuby::MemoryMap.pool_addr(0))
  end

  # 未対応の型 (float) はスロットを書かない
  def test_pool_float_is_skipped
    irep = build_irep(pool: [[:float, 1.5]])
    _em, image = load_image(irep)

    refute image.key?(FaRuby::MemoryMap.pool_addr(0))
    refute image.key?(FaRuby::MemoryMap.pool_type_addr(0))
  end

  # プール領域がデバイスマッピングテーブル (EM5000) を侵さないこと
  def test_pool_region_fits_before_device_table
    last = FaRuby::MemoryMap.pool_slot_addr(MAX_POOL - 1) + SLOT_WORDS - 1
    assert_operator last, :<, DEVICE_TABLE_BASE
  end

  # === 領域あふれ検証 ===

  def test_validate_rejects_pool_overflow
    irep = build_irep(pool: Array.new(MAX_POOL + 1) { [:int32, 1] })
    err = assert_raises(FaRuby::CodegenError) { FaRuby::PlcCodegen.new(irep).memory_image }
    assert_match(/定数プール/, err.message)
  end

  def test_validate_rejects_register_overflow
    irep = build_irep(nregs: MAX_REGS + 1)
    assert_raises(FaRuby::CodegenError) { FaRuby::PlcCodegen.new(irep).generate }
  end

  def test_validate_rejects_symbol_overflow
    irep = build_irep(symbols: Array.new(MAX_SYMBOLS + 1) { |i| "$v#{i}" })
    assert_raises(FaRuby::CodegenError) { FaRuby::PlcCodegen.new(irep).memory_image }
  end

  def test_validate_accepts_limits
    irep = build_irep(nregs: MAX_REGS, pool: Array.new(MAX_POOL) { [:int32, 1] })
    assert_equal FaRuby::PlcCodegen, FaRuby::PlcCodegen.new(irep).validate!.class
  end

  # === レジスタファイル ===

  def test_register_file_cleared_by_slot
    irep = build_irep(nregs: 3)
    _em, image = load_image(irep)

    3.times do |i|
      slot = FaRuby::MemoryMap.reg_slot_addr(i)
      SLOT_WORDS.times do |w|
        assert image.key?(slot + w), "EM#{slot + w} (R[#{i}] slot word #{w}) が初期化されていない"
        assert_equal 0, image[slot + w]
      end
    end
  end

  # レジスタ領域がバイトコード領域を侵さないこと
  def test_register_region_fits_before_bytecode
    last = FaRuby::MemoryMap.reg_slot_addr(MAX_REGS - 1) + SLOT_WORDS - 1
    assert_operator last, :<, BYTECODE_BASE
  end

  # === シンボル解析 (アクセス幅サフィックス) ===

  def assert_parsed(sym, device_type, address, access_type, bit)
    p = FaRuby::PlcCodegen.parse_device_symbol(sym)
    refute_nil p, "#{sym} が解析できない"
    assert_equal [device_type, address, access_type, bit],
                 [p[:device_type], p[:address], p[:access_type], p[:bit]], sym
  end

  def test_parse_word_device_suffixes
    assert_parsed("$DM100",  DEVICE_TYPE_DM, "100", ACCESS_S, false)  # 既定
    assert_parsed("$DM100S", DEVICE_TYPE_DM, "100", ACCESS_S, false)
    assert_parsed("$DM100U", DEVICE_TYPE_DM, "100", ACCESS_U, false)
    assert_parsed("$DM100L", DEVICE_TYPE_DM, "100", ACCESS_L, false)
    assert_parsed("$DM100D", DEVICE_TYPE_DM, "100", ACCESS_D, false)
    assert_parsed("$DM100F", DEVICE_TYPE_DM, "100", ACCESS_F, false)
    assert_parsed("$EM6000", DEVICE_TYPE_EM, "6000", ACCESS_S, false)
    assert_parsed("$ZF500L", DEVICE_TYPE_ZF, "500", ACCESS_L, false)
  end

  # ビットデバイスはサフィックスを取らない
  def test_parse_bit_devices
    assert_parsed("$MR10", DEVICE_TYPE_MR, "10", nil, true)
    assert_parsed("$R100", DEVICE_TYPE_R, "100", nil, true)
    assert_parsed("$T5",   DEVICE_TYPE_T, "5",   nil, true)
  end

  # $L100 (ラッチリレー) を $DM100L の L サフィックスと混同しないこと
  def test_parse_latch_relay_not_confused_with_long_suffix
    assert_parsed("$L100", DEVICE_TYPE_L, "100", nil, true)
  end

  # $B1F は16進アドレス。末尾 F を実数サフィックスと誤認しないこと
  def test_parse_hex_bit_device_not_confused_with_float_suffix
    assert_parsed("$B1F", DEVICE_TYPE_B, "1F", nil, true)
  end

  def test_parse_non_device_symbol
    assert_nil FaRuby::PlcCodegen.parse_device_symbol("$foo")
    assert_nil FaRuby::PlcCodegen.parse_device_symbol("$DM")
  end

  # dev コマンド用 ($ なし) も同じ解析をする
  def test_parse_device_name_bare
    p = FaRuby::PlcCodegen.parse_device_name("DM100L")
    assert_equal [DEVICE_TYPE_DM, "100", ACCESS_L, false],
                 [p[:device_type], p[:address], p[:access_type], p[:bit]]
  end

  # === アクセス幅のデバイステーブル出力 ===

  def test_device_table_stores_access_type
    irep = build_irep(symbols: ["$DM100", "$DM200L", "$MR10"])
    _em, image = load_image(irep)

    [[0, ACCESS_S], [1, ACCESS_L]].each do |idx, expected|
      addr = DEVICE_TABLE_BASE + idx * DEVICE_TABLE_STRIDE
      assert_equal expected, image[addr + 2], "シンボル #{idx} の access_type"
    end
    # ビットデバイスは 0 (未使用)
    assert_equal 0, image[DEVICE_TABLE_BASE + 2 * DEVICE_TABLE_STRIDE + 2]
  end

  # 汎用グローバルは Ruby の値を持つので常に32ビット
  def test_general_global_is_always_long
    irep = build_irep(symbols: ["$foo"])
    mappings = FaRuby::PlcCodegen.new(irep).device_mappings
    assert_equal ACCESS_L, mappings[0][:access_type]
  end

  # 実数はコンパイル時に弾く
  def test_float_access_is_rejected
    irep = build_irep(symbols: ["$DM100F"])
    err = assert_raises(FaRuby::CodegenError) { FaRuby::PlcCodegen.new(irep).memory_image }
    assert_match(/実数/, err.message)
    assert_match(/\$DM100F/, err.message)
  end

  # デバイステーブルが汎用グローバル領域を侵さないこと
  def test_device_table_fits_before_general_globals
    last = DEVICE_TABLE_BASE + (MAX_SYMBOLS - 1) * DEVICE_TABLE_STRIDE + DEVICE_TABLE_STRIDE - 1
    assert_operator last, :<, GENERAL_GLOBAL_BASE
  end

  # === デバイスマッピング ===

  def test_device_mappings_general_globals
    irep = build_irep(symbols: ["$foo", "$bar"])
    mappings = FaRuby::PlcCodegen.new(irep).device_mappings

    assert_equal [true, true], mappings.map { |m| m[:general] }
    assert_equal FaRuby::MemoryMap.general_global_addr(0), mappings[0][:z_offset]
    assert_equal FaRuby::MemoryMap.general_global_addr(1), mappings[1][:z_offset]
    # 値ワードのアドレスなのでスロット先頭ではない
    assert_equal GENERAL_GLOBAL_BASE + SLOT_VALUE_OFFSET, mappings[0][:z_offset]
  end

  # デバイス名付きシンボルは汎用領域を消費しない
  def test_device_mappings_mixed
    irep = build_irep(symbols: ["$DM100", "$foo", "$MR10", "$bar"])
    mappings = FaRuby::PlcCodegen.new(irep).device_mappings

    assert_equal [false, true, false, true], mappings.map { |m| m[:general] }
    assert_equal FaRuby::MemoryMap.general_global_addr(0), mappings[1][:z_offset]
    assert_equal FaRuby::MemoryMap.general_global_addr(1), mappings[3][:z_offset]
    assert_equal DEVICE_TYPE_DM, mappings[0][:device_type]
    assert_equal DEVICE_TYPE_MR, mappings[2][:device_type]
  end

  # 汎用グローバルのスロットは 0 初期化される
  def test_general_global_slots_cleared
    irep = build_irep(symbols: ["$foo"])
    _em, image = load_image(irep)

    slot = FaRuby::MemoryMap.general_global_slot_addr(0)
    SLOT_WORDS.times do |w|
      assert image.key?(slot + w), "EM#{slot + w} が初期化されていない"
      assert_equal 0, image[slot + w]
    end
  end

  # デバイスマッピングテーブルには値ワードのアドレスが入る
  def test_device_table_stores_value_address
    irep = build_irep(symbols: ["$foo"])
    _em, image = load_image(irep)

    table_addr = DEVICE_TABLE_BASE
    assert_equal DEVICE_TYPE_EM, image[table_addr]
    assert_equal FaRuby::MemoryMap.general_global_addr(0), image[table_addr + 1]
  end

  # === 生成される KV スクリプト ===

  def test_generate_emits_slot_addresses
    irep = build_irep(nregs: 2, pool: [[:int32, 99]])
    script = FaRuby::PlcCodegen.new(irep).generate

    # プールの型タグと値がそれぞれのアドレスに出力される
    assert_includes script, "EM#{FaRuby::MemoryMap.pool_type_addr(0)} = #{TT_INTEGER}"
    assert_includes script, "EM#{FaRuby::MemoryMap.pool_addr(0)}.L = 99"
    # レジスタクリアは 4 ワード/スロットの範囲を回る
    assert_includes script, "FOR Z1 = #{REG_FILE_BASE} TO #{REG_FILE_BASE + 2 * SLOT_WORDS - 1}"
  end
end
