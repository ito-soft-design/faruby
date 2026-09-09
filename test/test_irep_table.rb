# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/plc_codegen"
require_relative "../tools/kvs_generator"

# IREP テーブル
#
# メソッドを定義すると本体が子 irep になります。バイトコード・定数プール・
# シンボル表は全 irep で 1 つの領域を分け合い、各 irep の位置をこのテーブルに
# 入れて実行時に引きます。アドレスを生成コードに焼き込めなくなりました。
class TestIrepTable < Minitest::Test
  include FaRuby::VmConstants

  Layout = FaRuby::MemoryLayout

  def layout = Layout.default

  # 子 irep を持つ irep を組み立てる
  Irep = Struct.new(:instructions, :ilen, :pool, :symbols, :nregs, :nlocals, :children)

  def irep(bytes: [0x69], pool: [], symbols: [], nregs: 4, children: [])
    Irep.new(bytes.pack("C*"), bytes.size, pool, symbols, nregs, 1, children)
  end

  def codegen(root) = FaRuby::PlcCodegen.new(root, layout: layout)

  def entry_word(image, index, field)
    image[layout.irep_table_addr(index) + field]
  end

  # === 並び順 ===

  # 階層ごとに並べると同じ親の子が連続する。OP_METHOD のオペランドは親から見た
  # 子の番号なので、親の first_child を足すだけで通し番号になる。
  # 深さ優先では子が離れてしまい、この足し算ができない。
  def test_children_of_the_same_parent_are_numbered_consecutively
    leaf = -> { irep }
    root = irep(children: [irep(children: [leaf.call]), leaf.call, leaf.call])
    entries = codegen(root).irep_entries

    assert_equal 5, entries.size
    # トップレベルの子は 1, 2, 3 に連続して並ぶ
    assert_equal [1, 2, 3], (0...3).map { |b| entries[0][:first_child] + b }
    # 孫は親 (irep 1) の first_child から
    assert_equal 4, entries[1][:first_child]
  end

  # === 領域の割り当て ===

  def test_each_irep_gets_its_own_slice_of_each_area
    root = irep(bytes: [1, 2, 3], pool: [:x], symbols: %w[$DM100],
                children: [irep(bytes: [4, 5], pool: %i[y z], symbols: %w[abs])])
    entries = codegen(root).irep_entries

    assert_equal layout.bytecode_base, entries[0][:bytecode_base]
    assert_equal layout.bytecode_base + 3, entries[1][:bytecode_base]

    assert_equal layout.pool_base, entries[0][:pool_base]
    assert_equal layout.pool_base + SLOT_WORDS, entries[1][:pool_base]

    assert_equal layout.device_table_base, entries[0][:symbol_base]
    assert_equal layout.device_table_base + DEVICE_TABLE_STRIDE, entries[1][:symbol_base]
  end

  # === メモリイメージ ===

  def test_the_table_records_where_each_irep_lives
    child = irep(bytes: [7, 7], nregs: 6)
    root = irep(bytes: [1, 2, 3], nregs: 4, children: [child])
    image = codegen(root).fixed_image

    assert_equal layout.bytecode_base,
                 entry_word(image, 0, Layout::IREP_BYTECODE)
    assert_equal 3, entry_word(image, 0, Layout::IREP_BYTECODE_LEN)
    assert_equal 4, entry_word(image, 0, Layout::IREP_NREGS)
    assert_equal 1, entry_word(image, 0, Layout::IREP_FIRST_CHILD)

    assert_equal layout.bytecode_base + 3,
                 entry_word(image, 1, Layout::IREP_BYTECODE)
    assert_equal 2, entry_word(image, 1, Layout::IREP_BYTECODE_LEN)
    assert_equal 6, entry_word(image, 1, Layout::IREP_NREGS)
  end

  # 子 irep のバイトコードも転送される (以前はトップレベルだけだった)
  def test_child_bytecode_reaches_the_image
    root = irep(bytes: [1, 2, 3], children: [irep(bytes: [7, 8])])
    image = codegen(root).fixed_image

    assert_equal [1, 2, 3], (0..2).map { |i| image[layout.bytecode_base + i] }
    assert_equal [7, 8], (3..4).map { |i| image[layout.bytecode_base + i] }
  end

  # 実行はトップレベルの irep から始まる
  def test_the_vm_starts_on_the_top_level_irep
    root = irep(bytes: [1, 2, 3], nregs: 4, children: [irep(bytes: [7, 8], nregs: 9)])
    image = codegen(root).memory_image
    fixed = codegen(root).fixed_image

    assert_equal 0, image[layout.cur_irep_addr]
    assert_equal layout.bytecode_base, image[layout.cur_bytecode_addr]
    assert_equal layout.irep_table_base, image[layout.irep_table_addr_addr]
    refute_empty fixed, "固定領域のイメージが空"
    assert_equal 3, image[layout.bytecode_len_addr]
    assert_equal 4, image[layout.nregs_addr]
    assert_equal layout.offset_of(layout.reg_file_base), image[layout.reg_base_addr]
    assert_equal 0, image[layout.frame_sp_addr]
    assert_equal 2, image[layout.num_ireps_addr]
  end

  # === 上限 ===

  # 上限は全 irep の合計で見る。片方だけ見ていると隣の領域を壊す
  def test_limits_apply_to_the_total_across_ireps
    half = layout.max_bytecode / 2 + 1
    root = irep(bytes: [0] * half, children: [irep(bytes: [0] * half)])

    error = assert_raises(FaRuby::CodegenError) { codegen(root).validate! }
    assert_match(/バイトコード長/, error.message)
  end

  def test_too_many_ireps_is_an_error
    root = irep(children: Array.new(layout.max_ireps) { irep })

    error = assert_raises(FaRuby::CodegenError) { codegen(root).validate! }
    assert_match(/irep の数/, error.message)
  end

  # === ドキュメントの図 ===

  # doc/architecture.md の「irep の構造」に載せた例の数値。
  # 配置を変えると図が古くなるため、ここで気づけるようにしておく。
  def test_the_diagram_in_the_docs_matches_the_layout
    top = irep(bytes: [0] * 28, symbols: %w[twice quad $DM100], nregs: 4,
               children: [irep(bytes: [0] * 13, nregs: 6),
                          irep(bytes: [0] * 17, symbols: %w[twice], nregs: 7)])
    entries = codegen(top).irep_entries

    assert_equal [0, 128, 3128, 3728], [layout.irep_table_addr(0), layout.bytecode_base,
                                        layout.pool_base, layout.device_table_base],
                 "doc/architecture.md の図の領域先頭"
    assert_equal [8, 16], [layout.irep_table_addr(1), layout.irep_table_addr(2)]
    assert_equal [128, 156, 169], entries.map { |e| e[:bytecode_base] }
    # 引数を持たない irep 1 はシンボルを使わないので表を占有しない
    assert_equal [3728, 3740, 3740], entries.map { |e| e[:symbol_base] }
    assert_equal [1, 3, 3], entries.map { |e| e[:first_child] }
  end

  # === 生成コード ===

  # 命令ごとに IREP テーブルを引くとスキャンタイムが延びるため、
  # 切り替え時に VM 状態へ写して使う
  def test_generated_code_reads_the_current_irep_from_the_vm_state
    emitter = FaRuby::KvsEmitter.new(layout: layout)
    source = FaRuby::KvsGenerator.new.source

    assert_includes source, "Z1 = #{emitter.pc} + #{emitter.bytecode_offset}",
                    "命令フェッチは実行中の irep のバイトコードから読む"
    assert_includes source, emitter.reg_offset, "レジスタ窓も VM 状態から引く"
  end

  # 領域の先頭を定数で焼き込むと、子 irep を実行したときに
  # トップレベルのバイトコードを読み続けてしまう
  def test_no_area_base_is_baked_into_the_running_code
    source = FaRuby::KvsGenerator.new.source
    emitter = FaRuby::KvsEmitter.new(layout: layout)

    { "バイトコード" => layout.bytecode_base,
      "定数プール"   => layout.pool_base,
      "シンボル表"   => layout.device_table_base,
      "レジスタ"     => layout.reg_file_base }.each do |name, base|
      refute_includes source, "+ #{emitter.block_offset(base)}",
                      "#{name}の先頭が定数で焼き込まれている"
    end
  end

  # リセットでトップレベルの irep に戻る
  def test_reset_points_back_at_the_top_level_irep
    source = FaRuby::KvsGenerator.new.init_source
    emitter = FaRuby::KvsEmitter.new(layout: layout)

    assert_includes source, "#{emitter.state(layout.cur_irep_addr)} = 0"
    assert_includes source, "#{emitter.state(layout.frame_sp_addr)} = 0"
    assert_includes source, "#{emitter.state(layout.reg_base_addr)} = " \
                            "#{layout.offset_of(layout.reg_file_base)}"
  end
end
