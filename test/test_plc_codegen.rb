# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/mrb_parser"
require_relative "../tools/plc_codegen"
require_relative "../simulator/em_memory"

# PlcCodegen のユニットテスト
# 値スロット (4ワード = 型タグ + 32ビット値 + 予備) のレイアウトを検証します。
class TestPlcCodegen < Minitest::Test
  include FaRuby::VmConstants

# テストは既定レイアウト (faruby_default.yml) を使う。
# 利用者の faruby.yml に影響されないようにするため。
def layout
  FaRuby::MemoryLayout.default
end

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

    assert_equal TT_INTEGER, em.read_u16(layout.pool_type_addr(0))
    assert_equal 123456, em.read_s32(layout.pool_addr(0))
    assert_equal TT_INTEGER, em.read_u16(layout.pool_type_addr(1))
    assert_equal 7, em.read_s32(layout.pool_addr(1))
  end

  # 32ビット値がスロット境界をまたいで隣のエントリを壊さないこと
  def test_pool_slots_do_not_overlap
    irep = build_irep(pool: [[:int32, -1], [:int32, 42]])
    em, = load_image(irep)

    assert_equal(-1, em.read_s32(layout.pool_addr(0)))
    assert_equal 42, em.read_s32(layout.pool_addr(1))
    assert_equal TT_INTEGER, em.read_u16(layout.pool_type_addr(1))
  end

  def test_pool_stride_is_slot_words
    assert_equal SLOT_WORDS,
                 layout.pool_slot_addr(1) - layout.pool_slot_addr(0)
    assert_equal layout.pool_slot_addr(0) + SLOT_VALUE_OFFSET,
                 layout.pool_addr(0)
  end

  # int64 は下位32ビットのみ使用する (従来の挙動を維持)
  def test_pool_int64_truncated_to_32bit
    irep = build_irep(pool: [[:int64, 0x1_0000_0007]])
    em, = load_image(irep)

    assert_equal TT_INTEGER, em.read_u16(layout.pool_type_addr(0))
    assert_equal 7, em.read_s32(layout.pool_addr(0))
  end

  # 実数は IEEE754 単精度のビット列として格納する
  # (PLC 側は値ワードを .F で読む)
  def test_pool_float_is_stored_as_ieee754
    irep = build_irep(pool: [[:float, 1.5]])
    em, = load_image(irep)

    assert_equal TT_FLOAT, em.read_u16(layout.pool_type_addr(0))
    assert_equal 0x3FC00000, em.read_u32(layout.pool_addr(0))
  end

  # 対応していない型はスロットを 0 (TT_EMPTY) で埋める
  #
  # OP_LOADL はタグごと複製するため、書かずに残すと不定のタグを拾う。
  # TT_EMPTY なら少なくとも偽として扱われ、挙動が決まる。
  def test_unsupported_pool_entry_is_zeroed
    irep = build_irep(pool: [[:string, "hi"]])
    em, image = load_image(irep)

    assert image.key?(layout.pool_type_addr(0)), "タグを書かずに残さない"
    assert_equal TT_EMPTY, em.read_u16(layout.pool_type_addr(0))
    assert_equal 0, em.read_s32(layout.pool_addr(0))
  end

  # プール領域がデバイスマッピングテーブル (EM5000) を侵さないこと
  def test_pool_region_fits_before_device_table
    last = layout.pool_slot_addr(layout.max_pool - 1) + SLOT_WORDS - 1
    assert_operator last, :<, layout.device_table_base
  end

  # === 領域あふれ検証 ===

  def test_validate_rejects_pool_overflow
    irep = build_irep(pool: Array.new(layout.max_pool + 1) { [:int32, 1] })
    err = assert_raises(FaRuby::CodegenError) { FaRuby::PlcCodegen.new(irep).memory_image }
    assert_match(/定数プール/, err.message)
  end

  def test_validate_rejects_register_overflow
    irep = build_irep(nregs: layout.max_regs + 1)
    assert_raises(FaRuby::CodegenError) { FaRuby::PlcCodegen.new(irep).generate }
  end

  def test_validate_rejects_symbol_overflow
    irep = build_irep(symbols: Array.new(layout.max_symbols + 1) { |i| "$v#{i}" })
    assert_raises(FaRuby::CodegenError) { FaRuby::PlcCodegen.new(irep).memory_image }
  end

  def test_validate_accepts_limits
    irep = build_irep(nregs: layout.max_regs, pool: Array.new(layout.max_pool) { [:int32, 1] })
    assert_equal FaRuby::PlcCodegen, FaRuby::PlcCodegen.new(irep).validate!.class
  end

  # === レジスタファイル ===

  def test_register_file_cleared_by_slot
    irep = build_irep(nregs: 3)
    _em, image = load_image(irep)

    3.times do |i|
      slot = layout.reg_slot_addr(i)
      SLOT_WORDS.times do |w|
        assert image.key?(slot + w), "EM#{slot + w} (R[#{i}] slot word #{w}) が初期化されていない"
        assert_equal 0, image[slot + w]
      end
    end
  end

  # レジスタ領域がバイトコード領域を侵さないこと
  def test_register_region_fits_before_bytecode
    last = layout.reg_slot_addr(layout.max_regs - 1) + SLOT_WORDS - 1
    assert_operator last, :<, layout.bytecode_base
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
      addr = layout.device_table_base + idx * DEVICE_TABLE_STRIDE
      assert_equal expected, image[addr + 2], "シンボル #{idx} の access_type"
    end
    # サフィックス無しのビットデバイスは ACCESS_BIT。
    # 0 (ACCESS_S) と区別が要る。幅を付けると整数として扱われるため。
    assert_equal ACCESS_BIT, image[layout.device_table_base + 2 * DEVICE_TABLE_STRIDE + 2]
  end

  # ビットデバイスに幅を付けると整数として扱う
  # (MR 等はそのビットから連続したビット列、T / C は現在値)
  def test_bit_device_with_a_width_suffix_is_a_word_access
    irep = build_irep(symbols: ["$MR100", "$MR100L", "$MR100_L", "$T0D"])
    _em, image = load_image(irep)

    widths = (0..3).map { |i| image[layout.device_table_base + i * DEVICE_TABLE_STRIDE + 2] }
    assert_equal [ACCESS_BIT, ACCESS_L, ACCESS_L, ACCESS_D], widths
  end

  # B は16進アドレスなので D と F が数字と重なる。
  # アンダースコアで区切れば幅として読める。
  def test_hex_address_keeps_its_digits_unless_separated
    assert_equal 0x1F, FaRuby::PlcCodegen.parse_device_symbol("$B1F")[:z_offset]
    assert_nil FaRuby::PlcCodegen.parse_device_symbol("$B1F")[:access_type]

    separated = FaRuby::PlcCodegen.parse_device_symbol("$B1_F")
    assert_equal 0x1, separated[:z_offset]
    assert_equal ACCESS_F, separated[:access_type]
  end

  # KV が受け付ける略記 (E, D, M, L) は正式名に正規化する。
  # plc_access は略記を知らず、"L100" を受け付けても番号 100 を返して
  # LR100 (番号 16) と食い違うため、正規化しないと別のビットを読み書きする。
  ALIAS_PAIRS = {
    "$E100" => ["EM", DEVICE_TYPE_EM, 100],
    "$D100" => ["DM", DEVICE_TYPE_DM, 100],
    "$M100" => ["MR", DEVICE_TYPE_MR, 16],
    "$L100" => ["LR", DEVICE_TYPE_L,  16],
  }.freeze

  def test_shorthand_device_names_normalise_to_the_protocol_name
    ALIAS_PAIRS.each do |sym, (name, type, z_offset)|
      parsed = FaRuby::PlcCodegen.parse_device_symbol(sym)
      assert_equal name, parsed[:device_name], sym
      assert_equal type, parsed[:device_type], sym
      assert_equal z_offset, parsed[:z_offset], "#{sym} は #{name}100 と同じ番号"
    end
  end

  # 略記と正式名は同じものを指す
  def test_shorthand_matches_the_full_name
    { "$E100" => "$EM100", "$D100L" => "$DM100L",
      "$M100U" => "$MR100U", "$L100" => "$LR100" }.each do |short, full|
      assert_equal FaRuby::PlcCodegen.parse_device_symbol(full),
                   FaRuby::PlcCodegen.parse_device_symbol(short),
                   "#{short} と #{full}"
    end
  end

  def test_shorthand_device_families_normalise_too
    { "$L" => "LR", "$M" => "MR", "$D" => "DM", "$E" => "EM" }.each do |sym, name|
      assert_equal name, FaRuby::PlcCodegen.parse_device_family(sym)[:device_name], sym
    end
  end

  # 正式名を略記より先にマッチさせないと、LR100 が L + "R100"、
  # EM100 が E + "M100" になる
  def test_full_names_match_before_shorthands
    assert_equal 160, FaRuby::PlcCodegen.parse_device_symbol("$LR1000")[:z_offset]
    assert_equal DEVICE_TYPE_MR, FaRuby::PlcCodegen.parse_device_symbol("$MR100")[:device_type]
    assert_equal DEVICE_TYPE_EM, FaRuby::PlcCodegen.parse_device_symbol("$EM100")[:device_type]
    assert_equal DEVICE_TYPE_DM, FaRuby::PlcCodegen.parse_device_symbol("$DM100")[:device_type]
  end

  # $DML は DM + L。略記の D を先に取ると "ML" が幅として解釈できず壊れる
  def test_family_suffix_is_read_after_the_full_name
    assert_equal FaRuby::PlcCodegen.parse_device_family("$DL"),
                 FaRuby::PlcCodegen.parse_device_family("$DML")
  end

  # タイマ・カウンタは実数を扱えない (KV Studio の変換が通らない)
  def test_timer_and_counter_reject_float
    %w[$T0F $C0F $T0_F $T $C].each do |sym|
      next if %w[$T $C].include?(sym) # 幅無しは個別ビットなので対象外

      err = assert_raises(FaRuby::CodegenError, sym) { FaRuby::PlcCodegen.parse_device_symbol(sym) }
      assert_match(/実数/, err.message)
    end

    err = assert_raises(FaRuby::CodegenError) { FaRuby::PlcCodegen.parse_device_family("$TF") }
    assert_match(/実数/, err.message)
  end

  # 生成コードにも T / C の実数分岐を出さない
  def test_generated_code_has_no_float_branch_for_timers
    source = FaRuby::KvsGenerator.new.source
    refute_match(/\b[TC]0\.F:Z/, source)
    assert_match(/\bMR0\.F:Z/, source, "他のビットデバイスには残る")
  end

  # 10進アドレスのデバイスでは区切りが無くても曖昧にならない
  def test_decimal_address_needs_no_separator
    { "$T0D" => ACCESS_D, "$T0_D" => ACCESS_D, "$MR100L" => ACCESS_L,
      "$DM100_L" => ACCESS_L }.each do |sym, access|
      assert_equal access, FaRuby::PlcCodegen.parse_device_symbol(sym)[:access_type], sym
    end
  end

  # 汎用グローバルは Ruby の値を持つので常に32ビット
  def test_general_global_is_always_long
    irep = build_irep(symbols: ["$foo"])
    mappings = FaRuby::PlcCodegen.new(irep).device_mappings
    assert_equal ACCESS_L, mappings[0][:access_type]
  end

  # 実数デバイスはアクセス幅 F としてテーブルに載る
  def test_float_access_is_mapped
    irep = build_irep(symbols: ["$DM100F"])
    mappings = FaRuby::PlcCodegen.new(irep).device_mappings

    assert_equal ACCESS_F, mappings[0][:access_type]
    assert_equal DEVICE_TYPE_DM, mappings[0][:device_type]
    assert_equal "100", mappings[0][:address]
  end

  # デバイステーブルが汎用グローバル領域を侵さないこと
  def test_device_table_fits_before_general_globals
    last = layout.device_table_base + (layout.max_symbols - 1) * DEVICE_TABLE_STRIDE + DEVICE_TABLE_STRIDE - 1
    assert_operator last, :<, layout.general_global_base
  end

  # === デバイスマッピング ===

  def test_device_mappings_general_globals
    irep = build_irep(symbols: ["$foo", "$bar"])
    mappings = FaRuby::PlcCodegen.new(irep).device_mappings

    assert_equal [true, true], mappings.map { |m| m[:general] }
    assert_equal layout.general_global_addr(0), mappings[0][:z_offset]
    assert_equal layout.general_global_addr(1), mappings[1][:z_offset]
    # 値ワードのアドレスなのでスロット先頭ではない
    assert_equal layout.general_global_base + SLOT_VALUE_OFFSET, mappings[0][:z_offset]
  end

  # デバイス名付きシンボルは汎用領域を消費しない
  def test_device_mappings_mixed
    irep = build_irep(symbols: ["$DM100", "$foo", "$MR10", "$bar"])
    mappings = FaRuby::PlcCodegen.new(irep).device_mappings

    assert_equal [false, true, false, true], mappings.map { |m| m[:general] }
    assert_equal layout.general_global_addr(0), mappings[1][:z_offset]
    assert_equal layout.general_global_addr(1), mappings[3][:z_offset]
    assert_equal DEVICE_TYPE_DM, mappings[0][:device_type]
    assert_equal DEVICE_TYPE_MR, mappings[2][:device_type]
  end

  # 汎用グローバルのスロットは 0 初期化される
  def test_general_global_slots_cleared
    irep = build_irep(symbols: ["$foo"])
    _em, image = load_image(irep)

    slot = layout.general_global_slot_addr(0)
    SLOT_WORDS.times do |w|
      assert image.key?(slot + w), "EM#{slot + w} が初期化されていない"
      assert_equal 0, image[slot + w]
    end
  end

  # デバイスマッピングテーブルには値ワードのアドレスが入る
  def test_device_table_stores_value_address
    irep = build_irep(symbols: ["$foo"])
    _em, image = load_image(irep)

    table_addr = layout.device_table_base
    assert_equal DEVICE_TYPE_EM, image[table_addr]
    assert_equal layout.general_global_addr(0), image[table_addr + 1]
  end

  # === 生成される KV スクリプト ===

  def test_generate_emits_slot_addresses
    irep = build_irep(nregs: 2, pool: [[:int32, 99]])
    script = FaRuby::PlcCodegen.new(irep).generate

    # プールの型タグと値がそれぞれのアドレスに出力される
    assert_includes script, "EM#{layout.pool_type_addr(0)} = #{TT_INTEGER}"
    assert_includes script, "EM#{layout.pool_addr(0)}.L = 99"
    # レジスタクリアは 4 ワード/スロットの範囲を回る
    # 窓が呼び出しごとにずれるため、irep の nregs ではなく領域全体を回る
    assert_includes script,
                    "FOR Z1 = #{layout.reg_file_base} TO #{layout.reg_slot_addr(layout.max_regs) - 1}"
  end
end
