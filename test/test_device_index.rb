# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/plc_codegen"
require_relative "../tools/kvs_generator"
require_relative "../simulator/kv_vm_simulator"

# 添字によるデバイスアクセス
#
# デバイスアドレスはコンパイル時に確定するため、$DM100 では実行時に計算した
# アドレスを読み書きできません。裸の $DM を「デバイス族」とし、添字を付けて
# 実行時にアドレスを決めます。
class TestDeviceIndex < Minitest::Test
  include FaRuby::VmConstants

  Codegen = FaRuby::PlcCodegen

  def layout = FaRuby::MemoryLayout.default

  # === シンボルの解析 ===

  def test_bare_word_device_is_a_family
    parsed = Codegen.parse_device_family("$DM")

    assert parsed[:family]
    assert_equal DEVICE_TYPE_DM, parsed[:device_type]
    assert_equal ACCESS_S, parsed[:access_type], "既定は16ビット符号付き"
    assert_equal 0, parsed[:z_offset], "ベースアドレスは 0"
  end

  # 単独の D デバイスが無いため DM + L と一意に解析できる
  def test_family_accepts_a_width_suffix
    { "$DML" => ACCESS_L, "$DMU" => ACCESS_U, "$DMD" => ACCESS_D,
      "$DMF" => ACCESS_F, "$DMS" => ACCESS_S }.each do |sym, access|
      assert_equal access, Codegen.parse_device_family(sym)[:access_type], sym
    end
  end

  def test_family_covers_every_word_device
    { "$EM" => DEVICE_TYPE_EM, "$DM" => DEVICE_TYPE_DM, "$ZF" => DEVICE_TYPE_ZF }.each do |sym, type|
      assert_equal type, Codegen.parse_device_family(sym)[:device_type], sym
    end
  end

  # $L (ラッチリレー) は $DML の L サフィックスと衝突しない
  def test_latch_relay_is_not_confused_with_a_width_suffix
    assert_equal DEVICE_TYPE_DM, Codegen.parse_device_family("$DML")[:device_type]

    latch = Codegen.parse_device_family("$L")
    assert_equal DEVICE_TYPE_L, latch[:device_type]
    assert latch[:bit]
  end

  def test_family_covers_every_bit_device
    { "$MR" => DEVICE_TYPE_MR, "$R" => DEVICE_TYPE_R, "$B" => DEVICE_TYPE_B,
      "$L" => DEVICE_TYPE_L, "$T" => DEVICE_TYPE_T, "$C" => DEVICE_TYPE_C }.each do |sym, type|
      parsed = Codegen.parse_device_family(sym)
      assert_equal type, parsed[:device_type], sym
      assert parsed[:bit], sym
      assert_nil parsed[:access_type], "ビットデバイスに幅は無い"
    end
  end

  # 添字はデバイス番号。表示上のアドレスとは一致しないことがある
  # (MR400 は番号 64、B10 は 16)。番号空間では線形で加減算が通る。
  def test_index_is_the_device_number
    require "plc_access"
    kv = PlcAccess::Protocol::Keyence::KvDevice

    assert_equal 64, kv.new("MR400").number
    assert_equal 16, kv.new("B10").number
    assert_equal 600, kv.new("DM600").number, "ワードデバイスは表示と一致"
    # 番号空間では線形。MR415 の次は MR500
    assert_equal "MR500", (kv.new("MR415") + 1).name
  end

  # アドレス付きは従来どおりスカラ。$DM100[i] は成立しない
  # ($DM100 はスカラとしても使われ、どちらも同じ OP_GETGV になるため)
  def test_addressed_symbol_is_not_a_family
    assert_nil Codegen.parse_device_family("$DM100")
    refute Codegen.new(irep_with(["$DM100"])).device_mappings[0][:family]
  end

  def test_general_global_is_not_a_family
    assert_nil Codegen.parse_device_family("$foo")
  end

  # === デバイステーブル ===

  def test_family_is_marked_in_the_device_table
    mappings = Codegen.new(irep_with(["$DM", "$DM100"])).device_mappings

    assert mappings[0][:family], "$DM はデバイス族"
    refute mappings[1][:family], "$DM100 はスカラ"
  end

  def test_family_flag_reaches_the_memory_image
    image = Codegen.new(irep_with(["$DM"])).memory_image
    flag_addr = layout.device_table_base + DEVICE_TABLE_FAMILY_OFFSET

    assert_equal 1, image[flag_addr]
  end

  # === 生成コード ===

  def test_generated_code_branches_on_the_family_flag
    source = FaRuby::KvsGenerator.new.source
    assert_includes source, "デバイス族フラグ"
    assert_includes source, "#{FaRuby::KvsEmitter.new(layout: layout).reg_slot(:a).tag} = #{TT_DEVICE}"
  end

  # 範囲外は黙って別の場所を読み書きしてしまうため弾く
  # (EM は範囲外を読むと 512 ワード周期で値が返る)
  def test_generated_code_range_checks_the_address
    source = FaRuby::KvsGenerator.new.source
    assert_includes source, "<= 65535"
  end

  # 実行の検証は test_end_to_end.rb (mrbc で実際にコンパイルする側) にあります。

  def irep_with(symbols)
    irep = FaRuby::Irep.new
    irep.nregs = 8
    irep.nlocals = 2
    irep.instructions = "\x69" # OP_STOP
    irep.ilen = irep.instructions.bytesize
    symbols.each { |s| irep.add_symbol(s) }
    irep
  end
end
