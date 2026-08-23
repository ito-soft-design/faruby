# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/kvs_generator"
require_relative "../simulator/kv_vm_simulator"

# 型タグの扱い
#
# nil / true / false / 整数を区別し、Ruby と同じ真偽判定をすることを確認します。
# 値だけを見ていたころは nil も false も 0 も同じで、`if 0` が偽になっていました。
class TestTypes < Minitest::Test
  include FaRuby::VmConstants

  def layout = FaRuby::MemoryLayout.default

  def setup
    @sim = FaRuby::KvVmSimulator.new(layout: layout)
  end

  # バイトコードを積んで実行する
  def run_bytecode(bytes, nregs: 8)
    em = @sim.em
    em.write_u16(layout.pc_addr, 0)
    em.write_u16(layout.status_addr, VM_RUNNING)
    em.write_u16(layout.bytecode_len_addr, bytes.size)
    em.write_u16(layout.nregs_addr, nregs)
    bytes.each_with_index { |b, i| em.write_u16(layout.bytecode_addr(i), b) }
    @sim.run
  end

  def tag_of(index)   = @sim.em.read_u16(layout.reg_type_addr(index))
  def value_of(index) = @sim.em.read_s32(layout.reg_addr(index))

  STOP = 0x69

  # === タグの並び順 ===

  # 真偽判定を1比較で済ませるため、偽の2つが真より小さい番号になっている。
  # 並べ替えると生成コードの `タグ > TT_FALSY_MAX` が壊れる。
  def test_falsy_tags_sort_below_truthy_ones
    assert_operator TT_NIL,   :<=, TT_FALSY_MAX
    assert_operator TT_FALSE, :<=, TT_FALSY_MAX
    assert_operator TT_EMPTY, :<=, TT_FALSY_MAX, "未初期化は nil と同じく偽"

    [TT_TRUE, TT_INTEGER, TT_FLOAT, TT_SYMBOL, TT_STRING,
     TT_ARRAY, TT_HASH, TT_OBJECT].each do |tag|
      assert_operator tag, :>, TT_FALSY_MAX, "タグ #{tag} は真でなければならない"
    end
  end

  # === ロード命令が書くタグ ===

  def test_load_instructions_tag_their_values
    cases = {
      [0x11, 0x01] => [TT_NIL, 0],      # OP_LOADNIL
      [0x13, 0x01] => [TT_TRUE, 1],     # OP_LOADTRUE
      [0x14, 0x01] => [TT_FALSE, 0],    # OP_LOADFALSE
      [0x12, 0x01] => [TT_OBJECT, 0],   # OP_LOADSELF (main)
      [0x06, 0x01] => [TT_INTEGER, 0],  # OP_LOADI_0
      [0x0B, 0x01] => [TT_INTEGER, 5],  # OP_LOADI_5
      [0x05, 0x01] => [TT_INTEGER, -1], # OP_LOADI__1
    }

    cases.each do |bytes, (tag, value)|
      setup
      run_bytecode(bytes + [STOP])
      assert_equal tag, tag_of(1), "#{bytes.inspect} のタグ"
      assert_equal value, value_of(1), "#{bytes.inspect} の値"
    end
  end

  # true=1 / false=nil=0 にしてあるので、ビットデバイスへの書き込みは
  # 値だけで判定できる ($MR10 = true も $MR10 = 1 も ON)
  def test_boolean_values_match_bit_device_convention
    assert_equal 1, TT_CANONICAL_VALUE.fetch(TT_TRUE)
    assert_equal 0, TT_CANONICAL_VALUE.fetch(TT_FALSE)
    assert_equal 0, TT_CANONICAL_VALUE.fetch(TT_NIL)
  end

  # === 真偽判定 ===

  # JMPNOT (偽なら飛ぶ) で真偽を観測する。
  # 飛べば R[2] は未代入のまま、飛ばなければ 5 が入る。
  def falsy?(load_bytes)
    setup
    run_bytecode(load_bytes + [0x27, 0x01, 0x00, 0x02, 0x0B, 0x02, STOP])
    tag_of(2) != TT_INTEGER
  end

  def test_only_nil_and_false_are_falsy
    assert falsy?([0x11, 0x01]), "nil は偽"
    assert falsy?([0x14, 0x01]), "false は偽"

    refute falsy?([0x13, 0x01]), "true は真"
    refute falsy?([0x06, 0x01]), "整数の 0 も真 (Ruby の仕様)"
    refute falsy?([0x0B, 0x01]), "整数の 5 は真"
    refute falsy?([0x05, 0x01]), "整数の -1 は真"
    refute falsy?([0x12, 0x01]), "self は真"
  end

  # JMPNIL は nil だけに反応する。false では飛ばない
  def test_jmpnil_distinguishes_nil_from_false
    nil_jumped = begin
      run_bytecode([0x11, 0x01, 0x28, 0x01, 0x00, 0x02, 0x0B, 0x02, STOP])
      tag_of(2) != TT_INTEGER
    end
    setup
    false_jumped = begin
      run_bytecode([0x14, 0x01, 0x28, 0x01, 0x00, 0x02, 0x0B, 0x02, STOP])
      tag_of(2) != TT_INTEGER
    end

    assert nil_jumped, "nil なら飛ぶ"
    refute false_jumped, "false では飛ばない"
  end

  # === 等値比較 ===

  # OP_EQ は型も見る。値だけで比べると nil と false と 0 が同じになる
  def eq?(lhs_bytes, rhs_bytes)
    setup
    # lhs を R[1]、rhs を R[2] に置いてから OP_EQ R[1]
    run_bytecode(lhs_bytes + rhs_bytes + [0x42, 0x01, STOP])
    tag_of(1) == TT_TRUE
  end

  def test_equality_compares_type_as_well_as_value
    assert eq?([0x11, 0x01], [0x11, 0x02]), "nil == nil"
    assert eq?([0x14, 0x01], [0x14, 0x02]), "false == false"
    assert eq?([0x13, 0x01], [0x13, 0x02]), "true == true"
    assert eq?([0x0B, 0x01], [0x0B, 0x02]), "5 == 5"

    refute eq?([0x11, 0x01], [0x14, 0x02]), "nil == false は偽"
    refute eq?([0x14, 0x01], [0x06, 0x02]), "false == 0 は偽"
    refute eq?([0x13, 0x01], [0x07, 0x02]), "true == 1 は偽"
    refute eq?([0x0B, 0x01], [0x0A, 0x02]), "5 == 4 は偽"
  end

  # 比較結果は整数の 1/0 ではなく真偽値
  def test_comparison_yields_a_boolean
    run_bytecode([0x09, 0x01, 0x0A, 0x02, 0x43, 0x01, STOP]) # 3 < 4
    assert_equal TT_TRUE, tag_of(1)

    setup
    run_bytecode([0x0A, 0x01, 0x09, 0x02, 0x43, 0x01, STOP]) # 4 < 3
    assert_equal TT_FALSE, tag_of(1)
  end

  # === 除算 ===

  # Ruby の整数除算は切り下げ。KV スクリプトの / は 0 方向へ切り捨てるため、
  # 生成コード側で補正している (実機で -7 / 2 = -3 になることを確認済み)。
  def test_integer_division_rounds_toward_negative_infinity
    # R[1] = -7, R[2] = 2, R[1] = R[1] / R[2]
    run_bytecode([0x03, 0x01, 0xF9,  # OP_LOADI8 R[1], -7
                  0x08, 0x02,        # OP_LOADI_2 R[2]
                  0x41, 0x01,        # OP_DIV R[1]
                  STOP])
    assert_equal(-4, value_of(1), "Ruby と同じ切り下げ (0 方向への切り捨てなら -3)")
    assert_equal TT_INTEGER, tag_of(1)
  end

  # 生成コードに補正が入っていること (シミュレータは Ruby の / なので素通りする)
  def test_generated_division_corrects_toward_negative_infinity
    source = FaRuby::KvsGenerator.new.source
    emitter = FaRuby::KvsEmitter.new(layout: layout)
    assert_includes source, "#{emitter.scratch32_b} = "
    assert_match(/余り/, source)
  end

  # === 実数 ===

  # 値ワードには IEEE754 単精度のビット列が入る
  def float_of(index) = [@sim.em.read_u32(layout.reg_addr(index))].pack("V").unpack1("e")

  # プールに実数を置いて OP_LOADL で読む
  def load_float(index, value, reg: 1)
    @sim.em.write_u16(layout.pool_type_addr(index), TT_FLOAT)
    @sim.em.write_u32(layout.pool_addr(index), [value].pack("e").unpack1("V"))
    [0x02, reg, index] # OP_LOADL R[reg], Pool[index]
  end

  def test_pool_float_loads_with_its_tag
    run_bytecode(load_float(0, 1.5) + [STOP])
    assert_equal TT_FLOAT, tag_of(1)
    assert_in_delta 1.5, float_of(1), 1e-6
  end

  def test_float_arithmetic
    # R[1] = 2.5, R[2] = 0.5, R[1] = R[1] + R[2]
    run_bytecode(load_float(0, 2.5, reg: 1) + load_float(1, 0.5, reg: 2) +
                 [0x3C, 0x01, STOP])
    assert_equal TT_FLOAT, tag_of(1)
    assert_in_delta 3.0, float_of(1), 1e-6
  end

  # 整数と実数が混ざれば実数になる (Ruby と同じ)
  def test_mixed_arithmetic_promotes_to_float
    run_bytecode(load_float(0, 2.5, reg: 1) + [0x09, 0x02] + [0x3C, 0x01, STOP])
    assert_equal TT_FLOAT, tag_of(1)
    assert_in_delta 5.5, float_of(1), 1e-6
  end

  # 整数どうしは整数のまま。すべて実数にすると大きな整数の精度が落ちる
  def test_integer_arithmetic_stays_integer
    run_bytecode([0x09, 0x01, 0x0A, 0x02, 0x3C, 0x01, STOP])
    assert_equal TT_INTEGER, tag_of(1)
    assert_equal 7, value_of(1)
  end

  # 1 == 1.0 は真 (数値は型が違っても値で比べる)
  def test_integer_equals_float_of_the_same_value
    run_bytecode([0x07, 0x01] + load_float(0, 1.0, reg: 2) + [0x42, 0x01, STOP])
    assert_equal TT_TRUE, tag_of(1)
  end

  def test_numeric_comparison_across_types
    run_bytecode([0x07, 0x01] + load_float(0, 1.5, reg: 2) + [0x43, 0x01, STOP])
    assert_equal TT_TRUE, tag_of(1), "1 < 1.5"
  end

  # 実数どうしの除算は切り下げない
  def test_float_division_does_not_floor
    run_bytecode(load_float(0, 7.0, reg: 1) + load_float(1, 2.0, reg: 2) +
                 [0x41, 0x01, STOP])
    assert_equal TT_FLOAT, tag_of(1)
    assert_in_delta 3.5, float_of(1), 1e-6
  end

  # Ruby の 1.0 / 0 は Infinity で例外にならない
  def test_float_division_by_zero_yields_infinity
    run_bytecode(load_float(0, 1.0, reg: 1) + [0x06, 0x02] + [0x41, 0x01, STOP])
    assert_equal TT_FLOAT, tag_of(1)
    assert_equal Float::INFINITY, float_of(1)
    assert_equal VM_FINISHED, @sim.status, "エラー停止しない"
  end

  def test_negative_float_division_by_zero_yields_negative_infinity
    run_bytecode(load_float(0, -1.0, reg: 1) + [0x06, 0x02] + [0x41, 0x01, STOP])
    assert_equal(-Float::INFINITY, float_of(1))
  end

  def test_zero_divided_by_zero_yields_nan
    run_bytecode(load_float(0, 0.0, reg: 1) + [0x06, 0x02] + [0x41, 0x01, STOP])
    assert_predicate float_of(1), :nan?
  end

  # 生成コードは 0 除算を実行せずビット列を直接書く (KV は CR2012 を出すため)
  def test_generated_float_division_avoids_dividing_by_zero
    source = FaRuby::KvsGenerator.new.source
    assert_includes source, FaRuby::VmConstants::FLOAT_POS_INF_HI.to_s
    assert_includes source, FaRuby::VmConstants::FLOAT_NEG_INF_HI.to_s
    assert_includes source, FaRuby::VmConstants::FLOAT_NAN_HI.to_s
    assert_match(/CR2012/, source)
  end

  # 実数は単精度。倍精度のまま計算すると実機とずれる
  def test_floats_are_rounded_to_single_precision
    run_bytecode(load_float(0, 0.1, reg: 1) + [STOP])
    assert_equal [0.1].pack("e").unpack1("e"), float_of(1)
    refute_equal 0.1, float_of(1), "倍精度の 0.1 とは一致しない"
  end

  # === .mrb の実数リテラル ===

  # 実数だけはリトルエンディアンで書かれている。
  # RITE 形式の他の値と同じくビッグエンディアンで読むと値が化ける
  # (2.5 が 5.375e-321 になっていた)。
  def test_float_pool_entry_is_little_endian
    parser = FaRuby::MrbParser.new([0x05].pack("C") + [2.5].pack("E"))
    assert_equal 2.5, parser.send(:parse_pool_entry).value
  end

  # 整数プールは RITE 形式どおりビッグエンディアン
  def test_integer_pool_entry_is_big_endian
    parser = FaRuby::MrbParser.new([0x01].pack("C") + [1234].pack("N"))
    assert_equal 1234, parser.send(:parse_pool_entry).value
  end
end
