# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/opcode_table"
require_relative "../tools/kvs_generator"
require_relative "../simulator/kv_vm_simulator"

# 配列プール
#
# 配列の実体は固定数のスロットに置き、レジスタにはスロット番号だけを入れます。
# スロットは順に渡して返しません。使い切ると停止します。
#
# 添字アクセス・メソッド・each はまだ無いため、ここではバイトコードを
# 直接置いて OP_ARRAY / OP_ARRAY2 の単位で確かめます。
class TestArrays < Minitest::Test
  include FaRuby::VmConstants
  include FaRuby::OpcodeTable

  Layout = FaRuby::MemoryLayout

  def layout = Layout.default

  def setup
    @sim = FaRuby::KvVmSimulator.new(layout: layout)
  end

  ARRAY   = 0x47
  ARRAY2  = 0x48
  LOADI   = 0x03
  STOP    = 0x69

  def run_bytecode(bytes, nregs: 16)
    em = @sim.em
    em.write_u16(layout.pc_addr, 0)
    em.write_u16(layout.status_addr, VM_RUNNING)
    em.write_u16(layout.bytecode_len_addr, bytes.size)
    em.write_u16(layout.nregs_addr, nregs)
    bytes.each_with_index { |b, i| @sim.fixed.write_u16(layout.bytecode_addr(i), b) }
    @sim.run
  end

  # R[index] = value (整数)
  def load(index, value) = [LOADI, index, value]

  def tag_of(index)   = @sim.em.read_u16(layout.reg_type_addr(index))
  def value_of(index) = @sim.em.read_s32(layout.reg_addr(index))
  def status = @sim.em.read_u16(layout.status_addr)
  def error  = @sim.em.read_u16(layout.error_addr)

  def array_sp = @sim.em.read_u16(layout.array_sp_addr)

  def slot_length(index)
    @sim.em.read_u16(layout.array_slot_addr(index) + Layout::ARRAY_LENGTH)
  end

  # スロットの中身を [タグ, 値] の配列で返す
  def slot_elements(index)
    Array.new(slot_length(index)) do |i|
      addr = layout.array_element_addr(index, i)
      [@sim.em.read_u16(addr + SLOT_TYPE_OFFSET), @sim.em.read_s32(addr + SLOT_VALUE_OFFSET)]
    end
  end

  def slot_values(index) = slot_elements(index).map(&:last)

  # === OP_ARRAY2 ===

  def test_array2_copies_elements_from_a_separate_register_range
    run_bytecode(load(2, 11) + load(3, 22) + load(4, 33) + [ARRAY2, 1, 2, 3, STOP])

    assert_equal VM_FINISHED, status
    assert_equal TT_ARRAY, tag_of(1)
    assert_equal 0, value_of(1), "最初の配列はスロット 0"
    assert_equal 3, slot_length(0)
    assert_equal [11, 22, 33], slot_values(0)
  end

  def test_element_tags_are_copied_too
    run_bytecode([0x11, 2] + [0x13, 3] + load(4, 7) + [ARRAY2, 1, 2, 3, STOP])

    assert_equal [[TT_NIL, 0], [TT_TRUE, 1], [TT_INTEGER, 7]], slot_elements(0),
                 "nil / true / 整数がタグごと入る"
  end

  # === OP_ARRAY ===

  # R[a] が要素の先頭と結果を兼ねる。要素を写す前に R[a] を書くと壊れる
  def test_array_reads_its_elements_before_overwriting_the_destination
    run_bytecode(load(1, 11) + load(2, 22) + [ARRAY, 1, 2, STOP])

    assert_equal TT_ARRAY, tag_of(1)
    assert_equal [11, 22], slot_values(0)
  end

  def test_empty_array_takes_a_slot_with_no_elements
    run_bytecode([ARRAY, 1, 0, STOP])

    assert_equal VM_FINISHED, status
    assert_equal TT_ARRAY, tag_of(1)
    assert_equal 0, slot_length(0)
  end

  # === プールの消費 ===

  def test_each_array_takes_the_next_slot
    run_bytecode([ARRAY, 1, 0] + [ARRAY, 2, 0] + [ARRAY, 3, 0] + [STOP])

    assert_equal [0, 1, 2], [value_of(1), value_of(2), value_of(3)]
    assert_equal 3, array_sp
  end

  # 回収しないので、同じ場所を何度通っても消費し続ける
  def test_slots_are_never_returned
    bytes = ([ARRAY, 1, 0] * layout.max_arrays) + [STOP]
    run_bytecode(bytes)

    assert_equal VM_FINISHED, status
    assert_equal layout.max_arrays, array_sp
  end

  def test_running_out_of_slots_stops_the_vm
    bytes = ([ARRAY, 1, 0] * (layout.max_arrays + 1)) + [STOP]
    run_bytecode(bytes)

    assert_equal VM_ERROR, status
    assert_equal HEAP_ERROR, error
  end

  def test_more_elements_than_one_slot_holds_stops_the_vm
    run_bytecode([ARRAY, 1, layout.max_array_len + 1, STOP])

    assert_equal VM_ERROR, status
    assert_equal HEAP_ERROR, error
  end

  def test_exactly_the_capacity_is_allowed
    run_bytecode([ARRAY, 1, layout.max_array_len, STOP])

    assert_equal VM_FINISHED, status
    assert_equal layout.max_array_len, slot_length(0)
  end

  # === 配置 ===

  def test_the_pool_sits_after_the_globals_and_inside_the_block
    assert_equal layout.general_global_base + layout.max_globals * SLOT_WORDS,
                 layout.array_pool_base
    last = layout.array_slot_addr(layout.max_arrays) - 1

    assert_operator last, :<, layout.origin + layout.instance_size,
                    "プールがブロックからはみ出している"
  end

  def test_slots_do_not_overlap
    heads = Array.new(layout.max_arrays) { |i| layout.array_slot_addr(i) }
    gaps = heads.each_cons(2).map { |a, b| b - a }

    assert_equal [layout.array_slot_words] * (layout.max_arrays - 1), gaps
    assert_equal layout.array_slot_addr(0) + Layout::ARRAY_HEADER_WORDS,
                 layout.array_element_addr(0, 0)
  end

  # === 生成コード ===

  # 要素数 0 で「要素数 - 1」を計算すると、EM は16ビット符号なしなので
  # 65535 になり FOR が回り続ける。引き算は要素数が 1 以上のときだけ行う
  def test_the_element_loop_never_subtracts_from_zero
    source = FaRuby::KvsGenerator.new.source
    emitter = FaRuby::KvsEmitter.new(layout: layout)
    count = emitter.operand(:b)

    assert_includes source, "IF #{count} > 0 THEN"
    refute_includes source, "Z3 = #{count} - 1\n                IF Z3 >= 0 THEN"
  end

  def test_array_opcodes_are_implemented
    codes = FaRuby::OpcodeTable.codes

    assert_includes codes, 0x47, "OP_ARRAY が未実装"
    assert_includes codes, 0x48, "OP_ARRAY2 が未実装"
  end
end
