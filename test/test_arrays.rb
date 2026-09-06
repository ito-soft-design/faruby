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

  ARRAY    = 0x47
  ARRAY2   = 0x48
  LOADI    = 0x03
  LOADINEG = 0x04
  GETIDX   = 0x23
  SETIDX   = 0x24
  LOADSYM  = 0x10
  STOP     = 0x69

  def run_bytecode(bytes, nregs: 16)
    em = @sim.em
    em.write_u16(layout.pc_addr, 0)
    em.write_u16(layout.status_addr, VM_RUNNING)
    em.write_u16(layout.bytecode_len_addr, bytes.size)
    em.write_u16(layout.nregs_addr, nregs)
    bytes.each_with_index { |b, i| @sim.fixed.write_u16(layout.bytecode_addr(i), b) }
    @sim.run
  end

  # R[index] = value (整数)。オペランドは符号なしなので負値は専用命令
  def load(index, value)
    value.negative? ? [LOADINEG, index, -value] : [LOADI, index, value]
  end

  # R[1] に要素を詰めた配列を作り、R[2] に添字を置く
  def array_and_index(elements, index)
    elements.each_with_index.flat_map { |v, i| load(2 + i, v) } +
      [ARRAY2, 1, 2, elements.size] + load(2, index)
  end

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

  # === 添字読み (OP_GETIDX) ===

  def read_at(elements, index)
    run_bytecode(array_and_index(elements, index) + [GETIDX, 1, STOP])
  end

  def test_reading_an_element
    read_at([11, 22, 33], 1)

    assert_equal VM_FINISHED, status
    assert_equal TT_INTEGER, tag_of(1)
    assert_equal 22, value_of(1)
  end

  def test_reading_the_first_and_last_element
    read_at([11, 22, 33], 0)

    assert_equal 11, value_of(1)
    read_at([11, 22, 33], 2)

    assert_equal 33, value_of(1)
  end

  # Ruby の a[-1] は最後の要素
  def test_a_negative_index_counts_from_the_end
    read_at([11, 22, 33], -1)

    assert_equal 33, value_of(1)
    read_at([11, 22, 33], -3)

    assert_equal 11, value_of(1)
  end

  # Ruby は範囲外を nil で返す。エラーにはしない
  def test_reading_past_the_end_gives_nil
    read_at([11, 22, 33], 3)

    assert_equal VM_FINISHED, status
    assert_equal TT_NIL, tag_of(1)
  end

  def test_reading_before_the_start_gives_nil
    read_at([11, 22, 33], -4)

    assert_equal VM_FINISHED, status
    assert_equal TT_NIL, tag_of(1)
  end

  def test_reading_from_an_empty_array_gives_nil
    run_bytecode([ARRAY, 1, 0] + load(2, 0) + [GETIDX, 1, STOP])

    assert_equal VM_FINISHED, status
    assert_equal TT_NIL, tag_of(1)
  end

  # 配列でもデバイス族でもないものへの添字アクセスは止まる
  def test_indexing_a_number_stops_the_vm
    run_bytecode(load(1, 5) + load(2, 0) + [GETIDX, 1, STOP])

    assert_equal VM_ERROR, status
    assert_equal DEVICE_INDEX_ERROR, error
  end

  # === 添字書き (OP_SETIDX) ===

  def write_at(elements, index, value)
    run_bytecode(array_and_index(elements, index) + load(3, value) + [SETIDX, 1, STOP])
  end

  def test_writing_an_element
    write_at([11, 22, 33], 1, 99)

    assert_equal VM_FINISHED, status
    assert_equal [11, 99, 33], slot_values(0)
  end

  def test_writing_through_a_negative_index
    write_at([11, 22, 33], -1, 99)

    assert_equal [11, 22, 99], slot_values(0)
  end

  # Ruby は要素数を超える添字への代入で配列を伸ばす
  def test_writing_past_the_end_extends_the_array
    write_at([11], 1, 99)

    assert_equal VM_FINISHED, status
    assert_equal 2, slot_length(0)
    assert_equal [11, 99], slot_values(0)
  end

  # 間は nil で埋まる
  def test_the_gap_left_by_extending_is_filled_with_nil
    write_at([11], 3, 99)

    assert_equal 4, slot_length(0)
    assert_equal [[TT_INTEGER, 11], [TT_NIL, 0], [TT_NIL, 0], [TT_INTEGER, 99]],
                 slot_elements(0)
  end

  def test_writing_into_an_empty_array_extends_it
    run_bytecode([ARRAY, 1, 0] + load(2, 0) + load(3, 7) + [SETIDX, 1, STOP])

    assert_equal VM_FINISHED, status
    assert_equal [7], slot_values(0)
  end

  # 容量は固定なので、Ruby のように無限には伸ばせない
  def test_writing_past_the_capacity_stops_the_vm
    write_at([11], layout.max_array_len, 99)

    assert_equal VM_ERROR, status
    assert_equal HEAP_ERROR, error
  end

  def test_writing_at_the_last_position_of_the_capacity_is_allowed
    write_at([11], layout.max_array_len - 1, 99)

    assert_equal VM_FINISHED, status
    assert_equal layout.max_array_len, slot_length(0)
  end

  # 後ろから数えても先頭より前は Ruby では IndexError
  def test_writing_before_the_start_stops_the_vm
    write_at([11, 22], -3, 99)

    assert_equal VM_ERROR, status
    assert_equal DEVICE_INDEX_ERROR, error
  end

  def test_writing_does_not_take_another_slot
    write_at([11, 22], 0, 99)

    assert_equal 1, array_sp, "代入で新しいスロットを取ってはいけない"
  end

  # === メソッド (OP_SEND) ===

  SEND = 0x2F

  # シンボル表に 1 件だけメソッドを置く。引数の数を返す
  def put_method(name)
    code, argc = BUILTIN_METHODS.fetch(name)
    addr = layout.device_table_base
    @sim.fixed.write_u16(addr, code)
    @sim.fixed.write_u16(addr + 2, argc)
    @sim.fixed.write_u16(addr + DEVICE_TABLE_KIND_OFFSET, SYMBOL_KIND_METHOD)
    argc
  end

  # R[1] に配列を作り、R[2] を引数にしてメソッドを呼ぶ
  def call_on_array(elements, method_name, argument = nil)
    argc = put_method(method_name)
    setup = elements.each_with_index.flat_map { |v, i| load(2 + i, v) } +
            [ARRAY2, 1, 2, elements.size]
    setup += load(2, argument) if argument
    run_bytecode(setup + [SEND, 1, 0x00, argc, STOP])
  end

  def test_length_returns_the_element_count
    call_on_array([11, 22, 33], "length")

    assert_equal VM_FINISHED, status
    assert_equal TT_INTEGER, tag_of(1)
    assert_equal 3, value_of(1)
  end

  def test_length_of_an_empty_array_is_zero
    put_method("length")
    run_bytecode([ARRAY, 1, 0] + [SEND, 1, 0x00, 0, STOP])

    assert_equal VM_FINISHED, status
    assert_equal 0, value_of(1)
  end

  def test_push_appends_and_returns_the_array
    call_on_array([11], "push", 22)

    assert_equal VM_FINISHED, status
    assert_equal TT_ARRAY, tag_of(1), "push はレシーバ自身を返す"
    assert_equal [11, 22], slot_values(0)
    assert_equal 2, slot_length(0)
  end

  def test_push_onto_an_empty_array
    put_method("<<")
    run_bytecode([ARRAY, 1, 0] + load(2, 7) + [SEND, 1, 0x00, 1, STOP])

    assert_equal VM_FINISHED, status
    assert_equal [7], slot_values(0)
  end

  def test_push_does_not_take_another_slot
    call_on_array([11], "push", 22)

    assert_equal 1, array_sp
  end

  def test_pushing_past_the_capacity_stops_the_vm
    call_on_array(Array.new(layout.max_array_len) { 1 }, "push", 9)

    assert_equal VM_ERROR, status
    assert_equal HEAP_ERROR, error
  end

  # レシーバの型が合わないメソッドは止まる
  def test_an_array_method_on_a_number_stops_the_vm
    put_method("length")
    run_bytecode(load(1, 5) + [SEND, 1, 0x00, 0, STOP])

    assert_equal VM_ERROR, status
    assert_equal METHOD_TYPE_ERROR, error
  end

  # 数値メソッドの検査が「TT_INTEGER 以上」だったころ、
  # それより後ろのタグ (配列は 8) が数値として通っていた
  def test_a_numeric_method_on_an_array_stops_the_vm
    call_on_array([1], "abs")

    assert_equal VM_ERROR, status
    assert_equal METHOD_TYPE_ERROR, error
  end

  # === each のフレーム ===

  # each はブロックに添字ではなく要素を渡す。反復フレームの種別で分ける
  def test_each_uses_its_own_frame_kind
    refute_equal Layout::FRAME_KIND_ITERATE, Layout::FRAME_KIND_EACH
    assert_operator Layout::FRAME_KIND_EACH, :>, Layout::FRAME_KIND_ITERATE,
                    "「反復中か」を 1 比較で判定するため ITERATE 以上に置く"
    assert_operator Layout::FRAME_KIND_CALL, :<, Layout::FRAME_KIND_ITERATE
  end

  # h.each は鍵と値の 2 つを渡すので、a.each とも種別が違う
  def test_hash_each_has_its_own_frame_kind
    refute_equal Layout::FRAME_KIND_EACH, Layout::FRAME_KIND_HASH_EACH
    assert_operator Layout::FRAME_KIND_HASH_EACH, :>, Layout::FRAME_KIND_ITERATE,
                    "「反復中か」を 1 比較で判定するため ITERATE 以上に置く"
  end

  def test_each_takes_a_block_and_a_collection_receiver
    code, argc = BUILTIN_METHODS.fetch("each")

    assert_includes BLOCK_METHODS, code, "each はブロックを取る"
    assert_includes (METHOD_COLLECTION_MIN..METHOD_COLLECTION_MAX), code,
                    "each のレシーバは配列かハッシュ"
    assert_equal 0, argc
  end

  # 生成コードは「反復中か」を範囲で見る。等値のままだと each が素通りする
  def test_generated_code_treats_each_as_an_iteration
    source = FaRuby::KvsGenerator.new.source
    kind = "#{layout.device_name}#{Layout::FRAME_KIND}"

    refute_includes source, "#{kind}:Z3 = #{Layout::FRAME_KIND_ITERATE} THEN",
                    "反復の判定が等値のままになっている"
    assert_includes source, "#{kind}:Z3 >= #{Layout::FRAME_KIND_ITERATE} THEN"
  end

  # === 生成コード ===

  # Z1 は配列、Z2 は添字、Z3 は書き込む値が使っている。
  # スロットの見出しをこれらに置くと、値を書く前に壊れる
  def test_the_array_branch_does_not_clobber_the_value_register
    source = FaRuby::KvsGenerator.new.source
    setidx = source[/' OP_SETIDX .*?\n(.*?)\n            ELSE IF/m, 1]
    array_branch = setidx[/ELSE IF EM0:Z1 = #{TT_ARRAY} THEN\n(.*)/m, 1]

    refute_match(/^\s+Z[123] = /, array_branch,
                 "配列の枝が Z1-Z3 を書き換えている")
  end

  # === ハッシュ ===
  #
  # 実体は配列 2 本。専用のプールを作らないので、確保も容量検査も
  # 配列のものがそのまま効く

  HASH = 0x53

  # R[1] に鍵と値を交互に並べてから OP_HASH
  def build_hash(pairs)
    setup = pairs.each_with_index.flat_map do |(k, v), i|
      load(1 + i * 2, k) + load(2 + i * 2, v)
    end
    setup + [HASH, 1, pairs.size]
  end

  def test_a_hash_takes_two_array_slots
    run_bytecode(build_hash([[10, 11], [20, 22]]) + [STOP])

    assert_equal VM_FINISHED, status
    assert_equal TT_HASH, tag_of(1)
    assert_equal 2, array_sp, "鍵の配列と値の配列で 2 スロット"
    assert_equal [10, 20], slot_values(0), "スロット 0 が鍵"
    assert_equal [11, 22], slot_values(1), "スロット 1 が値"
  end

  def test_an_empty_hash_still_takes_two_slots
    run_bytecode([HASH, 1, 0, STOP])

    assert_equal VM_FINISHED, status
    assert_equal 2, array_sp
    assert_equal 0, slot_length(0)
  end

  def test_reading_a_key
    run_bytecode(build_hash([[10, 11], [20, 22]]) + load(2, 20) + [GETIDX, 1, STOP])

    assert_equal TT_INTEGER, tag_of(1)
    assert_equal 22, value_of(1)
  end

  def test_reading_a_missing_key_gives_nil
    run_bytecode(build_hash([[10, 11]]) + load(2, 99) + [GETIDX, 1, STOP])

    assert_equal VM_FINISHED, status
    assert_equal TT_NIL, tag_of(1)
  end

  def test_writing_an_existing_key_replaces_the_value
    run_bytecode(build_hash([[10, 11]]) + load(2, 10) + load(3, 99) + [SETIDX, 1, STOP])

    assert_equal VM_FINISHED, status
    assert_equal 1, slot_length(0), "鍵は増えない"
    assert_equal [99], slot_values(1)
  end

  def test_writing_a_new_key_appends_to_both_arrays
    run_bytecode(build_hash([[10, 11]]) + load(2, 20) + load(3, 22) + [SETIDX, 1, STOP])

    assert_equal [10, 20], slot_values(0)
    assert_equal [11, 22], slot_values(1)
  end

  def test_writing_a_hash_key_does_not_take_another_slot
    run_bytecode(build_hash([[10, 11]]) + load(2, 20) + load(3, 22) + [SETIDX, 1, STOP])

    assert_equal 2, array_sp
  end

  def test_filling_a_hash_past_the_capacity_stops_the_vm
    pairs = Array.new(layout.max_array_len) { |i| [i, i] }
    run_bytecode(build_hash(pairs) + load(2, 99) + load(3, 0) + [SETIDX, 1, STOP])

    assert_equal VM_ERROR, status
    assert_equal HEAP_ERROR, error
  end

  # ハッシュ 1 つが 2 スロット。奇数個目でも 2 つ空いていないと作れない
  def test_a_hash_needs_two_free_slots
    fill = [ARRAY, 5, 0] * (layout.max_arrays - 1)
    run_bytecode(fill + [HASH, 1, 0, STOP])

    assert_equal VM_ERROR, status
    assert_equal HEAP_ERROR, error
  end

  # 鍵は型と値の両方で照合する。Ruby の Hash も eql? で引く
  def test_keys_match_on_type_as_well_as_value
    put_method("length")   # シンボルを 1 件用意する
    run_bytecode([LOADI, 1, 10] + [LOADI, 2, 11] + [HASH, 1, 1] +
                 [LOADSYM, 2, 0x00] + [GETIDX, 1, STOP])

    assert_equal VM_FINISHED, status
    assert_equal TT_NIL, tag_of(1), "整数の鍵 10 とシンボルは別物"
  end

  # === ハッシュのメソッド ===

  # R[1] にハッシュを作り、R[2] を引数にしてメソッドを呼ぶ
  def call_on_hash(pairs, method_name, argument = nil)
    argc = put_method(method_name)
    setup = build_hash(pairs)
    setup += load(2, argument) if argument
    run_bytecode(setup + [SEND, 1, 0x00, argc, STOP])
  end

  def test_size_of_a_hash_is_the_pair_count
    call_on_hash([[10, 11], [20, 22]], "size")

    assert_equal VM_FINISHED, status
    assert_equal TT_INTEGER, tag_of(1)
    assert_equal 2, value_of(1)
  end

  def test_size_of_an_empty_hash_is_zero
    call_on_hash([], "length")

    assert_equal VM_FINISHED, status
    assert_equal 0, value_of(1)
  end

  # ハッシュの値スロットは下位ワードだけが鍵の配列の番号。配列と同じ
  # 32 ビット読みをすると値の配列の番号が上位に混ざり、別の場所を見る
  def test_length_reads_only_the_lower_word_of_a_hash
    call_on_hash([[10, 11]], "size")

    assert_equal 1, value_of(1)
  end

  def test_key_p_finds_an_existing_key
    call_on_hash([[10, 11], [20, 22]], "key?", 20)

    assert_equal VM_FINISHED, status
    assert_equal TT_TRUE, tag_of(1)
  end

  def test_key_p_is_false_for_a_missing_key
    call_on_hash([[10, 11]], "key?", 99)

    assert_equal TT_FALSE, tag_of(1)
  end

  def test_key_p_on_an_empty_hash_is_false
    call_on_hash([], "key?", 1)

    assert_equal VM_FINISHED, status
    assert_equal TT_FALSE, tag_of(1)
  end

  def test_keys_returns_a_new_array
    call_on_hash([[10, 11], [20, 22]], "keys")

    assert_equal VM_FINISHED, status
    assert_equal TT_ARRAY, tag_of(1)
    assert_equal 3, array_sp, "鍵と値の 2 つに加えて新しい 1 つ"
    assert_equal [10, 20], slot_values(2)
  end

  def test_values_returns_a_new_array
    call_on_hash([[10, 11], [20, 22]], "values")

    assert_equal TT_ARRAY, tag_of(1)
    assert_equal [11, 22], slot_values(2)
  end

  # レシーバはハッシュから配列に変わる。値ワードを 32 ビットで書くので
  # 上位に残っていた値の配列の番号も消える
  def test_keys_leaves_the_receiver_pointing_at_the_new_array
    call_on_hash([[10, 11]], "keys")

    assert_equal 2, value_of(1)
  end

  def test_keys_of_an_empty_hash_is_an_empty_array
    call_on_hash([], "keys")

    assert_equal VM_FINISHED, status
    assert_equal 0, slot_length(2)
  end

  # 返さないスロットを 1 つ取るため、プールが尽きていると作れない
  def test_keys_with_a_full_pool_stops_the_vm
    argc = put_method("keys")
    fill = [ARRAY, 5, 0] * (layout.max_arrays - 2)
    run_bytecode(build_hash([[10, 11]]) + fill + [SEND, 1, 0x00, argc, STOP])

    assert_equal VM_ERROR, status
    assert_equal HEAP_ERROR, error
  end

  # レシーバの型で番号を並べているので、範囲比較だけで弾ける
  def test_a_hash_method_on_an_array_stops_the_vm
    call_on_array([1, 2], "keys")

    assert_equal VM_ERROR, status
    assert_equal METHOD_TYPE_ERROR, error
  end

  def test_an_array_method_on_a_hash_stops_the_vm
    call_on_hash([[10, 11]], "push", 1)

    assert_equal VM_ERROR, status
    assert_equal METHOD_TYPE_ERROR, error
  end

  # length と size だけは配列とハッシュの両方を受ける
  def test_length_accepts_an_array_and_a_hash
    code = BUILTIN_METHODS.fetch("length").first

    assert_includes (METHOD_COLLECTION_MIN..METHOD_COLLECTION_MAX), code
    assert_equal code, BUILTIN_METHODS.fetch("size").first
  end

  # Z1 はレシーバで、写し終えてから配列に書き換える。
  # 途中で使うと元のハッシュを見失う
  def test_the_hash_column_branch_does_not_clobber_the_receiver_register
    source = FaRuby::KvsGenerator.new.source
    branch = source[/' keys\n(.*?)ELSE IF Z5 = /m, 1]

    refute_match(/^\s+Z1 = /, branch, "keys の枝が Z1 を書き換えている")
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
