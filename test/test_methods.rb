# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/kvs_generator"
require_relative "../tools/plc_codegen"
require_relative "../tools/opcode_table"
require_relative "../simulator/kv_vm_simulator"

# 組み込みメソッド (OP_SEND の限定実装)
#
# 呼び出しフレームを作らず、その場で計算して R[a] に返します。
# メソッド名はホスト側で番号に解決し、VM は整数の分岐だけで振り分けます。
class TestMethods < Minitest::Test
  include FaRuby::VmConstants
  include FaRuby::OpcodeTable

  def layout = FaRuby::MemoryLayout.default

  def setup
    @sim = FaRuby::KvVmSimulator.new(layout: layout)
  end

  SEND = 0x2F
  STOP = 0x69

  # シンボル表に 1 件だけメソッドを置く
  def put_method(name, index: 0)
    code, argc = BUILTIN_METHODS.fetch(name, [METHOD_NONE, 0])
    # シンボル表は固定領域 (FM) にある
    addr = layout.device_table_base + index * DEVICE_TABLE_STRIDE
    @sim.fixed.write_u16(addr, code)
    @sim.fixed.write_u16(addr + 2, argc)
    @sim.fixed.write_u16(addr + DEVICE_TABLE_KIND_OFFSET, SYMBOL_KIND_METHOD)
    argc
  end

  def set_reg(index, tag, value)
    @sim.em.write_u16(layout.reg_type_addr(index), tag)
    if tag == TT_FLOAT
      @sim.em.write_u32(layout.reg_addr(index), FaRuby::SimVm.float_bits(value))
    else
      @sim.em.write_s32(layout.reg_addr(index), value)
    end
  end

  # R[0] にレシーバ、R[1] に引数を置いて R[0].name(R[1]) を実行する
  def call(name, receiver, argument = nil)
    set_reg(0, *receiver)
    set_reg(1, *argument) if argument
    argc = put_method(name)
    run_bytecode([SEND, 0x00, 0x00, argc, STOP])
  end

  def run_bytecode(bytes, nregs: 8)
    em = @sim.em
    em.write_u16(layout.pc_addr, 0)
    em.write_u16(layout.status_addr, VM_RUNNING)
    em.write_u16(layout.bytecode_len_addr, bytes.size)
    em.write_u16(layout.nregs_addr, nregs)
    # バイトコードは固定領域 (FM) にある
    bytes.each_with_index { |b, i| @sim.fixed.write_u16(layout.bytecode_addr(i), b) }
    @sim.run
  end

  def tag_of(index)   = @sim.em.read_u16(layout.reg_type_addr(index))
  def value_of(index) = @sim.em.read_s32(layout.reg_addr(index))
  def float_of(index) = FaRuby::SimVm.bits_to_float(@sim.em.read_u32(layout.reg_addr(index)))
  def status          = @sim.em.read_u16(layout.status_addr)
  def error           = @sim.em.read_u16(layout.error_addr)

  INT   = ->(v) { [TT_INTEGER, v] }
  FLOAT = ->(v) { [TT_FLOAT, v] }

  # === 定数表 ===

  # 数値レシーバを要求するメソッドを連続した番号に並べてあるため、
  # 生成コードは `Z5 >= METHOD_NUMERIC_MIN` の1比較で判定できる。
  # 並べ替えるとレシーバの型検査が壊れる。
  def test_numeric_methods_sort_above_the_others
    %w[! !=].each do |name|
      assert_operator BUILTIN_METHODS.fetch(name).first, :<, METHOD_NUMERIC_MIN, name
    end
    %w[% abs to_i to_f floor round].each do |name|
      assert_operator BUILTIN_METHODS.fetch(name).first, :>=, METHOD_NUMERIC_MIN, name
    end
  end

  # 未対応を表す 0 は本体を持たない
  def test_method_none_has_no_body
    refute_includes METHOD_NAMES.keys, METHOD_NONE
  end

  # === != ===

  def test_not_equal_compares_value_and_type
    { [INT.(1), INT.(2)]          => TT_TRUE,
      [INT.(1), INT.(1)]          => TT_FALSE,
      [INT.(1), FLOAT.(1.0)]      => TT_FALSE,   # 数値は型が違っても値で比べる
      [[TT_NIL, 0], [TT_FALSE, 0]] => TT_TRUE }.each do |(lhs, rhs), expected|
      call("!=", lhs, rhs)
      assert_equal expected, tag_of(0), "#{lhs.inspect} != #{rhs.inspect}"
    end
  end

  # === ! ===

  # Ruby で偽なのは nil と false だけ。0 も空も真
  def test_not_follows_ruby_truthiness
    { [TT_NIL, 0]     => TT_TRUE,
      [TT_FALSE, 0]   => TT_TRUE,
      [TT_TRUE, 1]    => TT_FALSE,
      [TT_INTEGER, 0] => TT_FALSE }.each do |receiver, expected|
      call("!", receiver)
      assert_equal expected, tag_of(0), receiver.inspect
    end
  end

  # === % ===

  # Ruby の % は商を切り下げた余りで、符号は除数に合う
  def test_modulo_follows_the_divisor_sign
    { [7, 3] => 1, [-7, 3] => 2, [7, -3] => -2, [-7, -3] => -1, [6, 3] => 0 }.each do |(a, b), expected|
      call("%", INT.(a), INT.(b))
      assert_equal expected, value_of(0), "#{a} % #{b}"
      assert_equal TT_INTEGER, tag_of(0)
    end
  end

  def test_modulo_by_zero_stops_the_vm
    call("%", INT.(7), INT.(0))
    assert_equal VM_ERROR, status
    assert_equal DIVIDE_BY_ZERO_ERROR, error
  end

  # 実数の % は未対応
  def test_modulo_rejects_floats
    call("%", FLOAT.(7.5), INT.(3))
    assert_equal VM_ERROR, status
    assert_equal METHOD_TYPE_ERROR, error
  end

  # === 数値変換 ===

  def test_abs_keeps_the_type
    call("abs", INT.(-3))
    assert_equal [TT_INTEGER, 3], [tag_of(0), value_of(0)]

    call("abs", FLOAT.(-2.5))
    assert_equal [TT_FLOAT, 2.5], [tag_of(0), float_of(0)]
  end

  # Ruby の Float#to_i は 0 方向へ切り捨て
  def test_to_i_truncates_toward_zero
    { 2.7 => 2, -2.7 => -2, 2.0 => 2 }.each do |input, expected|
      call("to_i", FLOAT.(input))
      assert_equal [TT_INTEGER, expected], [tag_of(0), value_of(0)], input.to_s
    end
  end

  def test_to_f_converts_integers
    call("to_f", INT.(3))
    assert_equal [TT_FLOAT, 3.0], [tag_of(0), float_of(0)]
  end

  # floor は -∞ 方向。to_i との違いが出るのは負の端数
  def test_floor_rounds_down
    { 2.7 => 2, -2.7 => -3, -2.0 => -2 }.each do |input, expected|
      call("floor", FLOAT.(input))
      assert_equal [TT_INTEGER, expected], [tag_of(0), value_of(0)], input.to_s
    end
  end

  # Ruby の round は 0 から遠い方へ丸める
  def test_round_goes_away_from_zero
    { 2.5 => 3, -2.5 => -3, 2.4 => 2, -2.4 => -2 }.each do |input, expected|
      call("round", FLOAT.(input))
      assert_equal [TT_INTEGER, expected], [tag_of(0), value_of(0)], input.to_s
    end
  end

  # 整数レシーバは変換の必要がないのでそのまま返る
  def test_conversions_leave_integers_alone
    %w[to_i floor round].each do |name|
      call(name, INT.(5))
      assert_equal [TT_INTEGER, 5], [tag_of(0), value_of(0)], name
    end
  end

  # === エラー ===

  def test_unknown_method_stops_the_vm
    call("push", INT.(3))
    assert_equal VM_ERROR, status
    assert_equal UNKNOWN_METHOD_ERROR, error
  end

  def test_non_numeric_receiver_stops_the_vm
    call("abs", [TT_NIL, 0])
    assert_equal VM_ERROR, status
    assert_equal METHOD_TYPE_ERROR, error
  end

  # メソッド名でないシンボル ($DM100 など) は呼べない
  def test_calling_a_variable_symbol_stops_the_vm
    set_reg(0, TT_INTEGER, 3)
    addr = layout.device_table_base
    @sim.fixed.write_u16(addr + DEVICE_TABLE_KIND_OFFSET, SYMBOL_KIND_VALUE)
    run_bytecode([SEND, 0x00, 0x00, 0x00, STOP])
    assert_equal VM_ERROR, status
    assert_equal UNKNOWN_METHOD_ERROR, error
  end

  def test_argument_count_must_match
    set_reg(0, TT_INTEGER, 3)
    put_method("abs")   # 引数 0 個
    run_bytecode([SEND, 0x00, 0x00, 0x01, STOP])
    assert_equal VM_ERROR, status
    assert_equal UNKNOWN_METHOD_ERROR, error
  end

  # === ホスト側のシンボル解決 ===

  # メソッド名は汎用グローバル変数の枠を消費しない
  def test_method_symbols_resolve_to_numbers
    irep = Struct.new(:symbols, :pool, :instructions, :ilen, :nregs, :nlocals, :children)
                 .new(["$DM100", "abs", "push"], [], "", 0, 8, 0, [])
    mappings = FaRuby::PlcCodegen.new(irep).device_mappings

    assert_equal SYMBOL_KIND_VALUE, mappings[0][:kind]
    assert_equal [SYMBOL_KIND_METHOD, METHOD_ABS, 0],
                 mappings[1].values_at(:kind, :method_code, :argc)
    assert_equal METHOD_NONE, mappings[2][:method_code], "未対応のメソッドは 0"
    refute mappings[1][:general], "メソッド名は汎用グローバルを消費しない"
  end

  # === 生成コード ===

  def test_generated_code_dispatches_on_the_method_number
    source = FaRuby::KvsGenerator.new.source

    assert_includes source, "' メソッド番号"
    assert_includes source, "IF Z5 >= #{METHOD_NUMERIC_MIN} THEN"
    METHOD_NAMES.each_key do |code|
      assert_includes source, "IF Z5 = #{code} THEN", "メソッド番号 #{code} の分岐"
    end
  end
end
