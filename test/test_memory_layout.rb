# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/config"
require_relative "../tools/kvs_generator"
require_relative "../simulator/kv_vm_simulator"

# メモリ配置と設定読み込みのテスト
class TestMemoryLayout < Minitest::Test
  include FaRuby::VmConstants

  Layout = FaRuby::MemoryLayout

  def build(**opts)
    Layout.new(**opts)
  end

  # === 領域の計算 ===

  # 各領域はサイズ設定から詰めて並ぶ
  def test_regions_are_packed_in_order
    l = build(base: 0, max_regs: 10, max_bytecode: 100, max_pool: 5,
              max_symbols: 4, max_globals: 3)

    assert_equal 0, l.vm_state_base
    assert_equal Layout::VM_STATE_WORDS, l.reg_file_base
    assert_equal l.reg_file_base + 10 * SLOT_WORDS, l.bytecode_base
    assert_equal l.bytecode_base + 100, l.pool_base
    assert_equal l.pool_base + 5 * SLOT_WORDS, l.device_table_base
    assert_equal l.device_table_base + 4 * DEVICE_TABLE_STRIDE, l.general_global_base
  end

  # 領域が重ならず、隙間なく並ぶ
  def test_regions_do_not_overlap
    l = Layout.default
    l.regions.each_cons(2) do |(_, _, prev_to, _), (name, from, _, _)|
      assert_equal prev_to + 1, from, "#{name} が前の領域と連続していない"
    end
  end

  def test_instance_size_is_sum_of_regions
    l = Layout.default
    assert_equal l.instance_size, l.regions.sum { |_, _, _, words| words }
  end

  # === 端数の切り上げ ===

  # ブロックサイズは align の倍数に切り上げられる
  def test_instance_size_is_aligned
    l = build(align: 1000)
    assert_equal 0, l.instance_size % 1000
    assert_operator l.instance_size, :>=, l.content_size
    assert_equal l.instance_size - l.content_size, l.padding
  end

  # 開始と終了が区切りの良い値になる
  def test_aligned_layout_has_round_boundaries
    l = build(base: 15_000, align: 1000)
    assert_equal 15_000, l.base
    assert_equal 19_999, l.last_addr
  end

  # 複数インスタンスでも各ブロックが丸い境界に載る
  def test_aligned_instances_start_on_round_boundaries
    l = build(base: 15_000, align: 1000, instances: 3)
    assert_equal [15_000, 20_000, 25_000], (0..2).map { |i| l.for_instance(i).origin }
  end

  # align: 1 なら切り上げない
  def test_alignment_can_be_disabled
    l = build(align: 1)
    assert_equal l.content_size, l.instance_size
    assert_equal 0, l.padding
  end

  # 切り上げ分は末尾の予備領域として現れ、他の領域を侵さない
  def test_padding_is_reported_as_a_region
    l = build(base: 0, align: 1000)
    skip "端数なし" if l.padding.zero?

    name, from, to, words = l.regions.last
    assert_equal "予備 (端数調整)", name
    assert_equal l.padding, words
    assert_equal l.instance_size - 1, to
    assert_operator from, :>, l.general_global_base
  end

  # === base による移動 ===

  # base を変えると全アドレスが同じだけずれる
  def test_base_shifts_every_address
    a = build(base: 0)
    b = build(base: 10_000)

    assert_equal a.pc_addr + 10_000,          b.pc_addr
    assert_equal a.reg_file_base + 10_000,    b.reg_file_base
    assert_equal a.bytecode_base + 10_000,    b.bytecode_base
    assert_equal a.pool_base + 10_000,        b.pool_base
    assert_equal a.device_table_base + 10_000, b.device_table_base
    assert_equal a.reg_addr(5) + 10_000,      b.reg_addr(5)
    assert_equal a.instance_size,             b.instance_size
  end

  # ラダーが使う領域を避けられること (今回の設定機能の目的)
  def test_can_be_relocated_above_ladder_area
    l = build(base: 20_000)
    assert_operator l.base, :>, 10_000
    assert_equal 20_000, l.vm_state_base
    assert_equal 20_000 + l.instance_size - 1, l.last_addr
  end

  # === 複数インスタンス ===

  def test_instances_are_laid_out_sequentially
    l = build(base: 1000, instances: 3)

    assert_equal 1000,                        l.for_instance(0).origin
    assert_equal 1000 + l.instance_size,      l.for_instance(1).origin
    assert_equal 1000 + l.instance_size * 2,  l.for_instance(2).origin
  end

  def test_instances_do_not_overlap
    l = build(base: 0, instances: 3)
    (0..1).each do |i|
      current = l.for_instance(i)
      following = l.for_instance(i + 1)
      assert_operator current.origin + current.instance_size, :<=, following.origin
    end
  end

  def test_total_words_covers_all_instances
    l = build(instances: 4)
    assert_equal l.instance_size * 4, l.total_words
  end

  def test_out_of_range_instance_is_rejected
    l = build(instances: 2)
    assert_raises(FaRuby::LayoutError) { l.for_instance(2) }
    assert_raises(FaRuby::LayoutError) { l.for_instance(-1) }
  end

  # === 値スロット ===

  def test_slot_addresses
    l = build(base: 100)
    assert_equal l.reg_file_base,                       l.reg_slot_addr(0)
    assert_equal l.reg_file_base + SLOT_VALUE_OFFSET,   l.reg_addr(0)
    assert_equal l.reg_file_base + SLOT_TYPE_OFFSET,    l.reg_type_addr(0)
    assert_equal SLOT_WORDS, l.reg_slot_addr(1) - l.reg_slot_addr(0)
    assert_equal SLOT_WORDS, l.pool_slot_addr(1) - l.pool_slot_addr(0)
  end

  # === 設定の検証 ===

  def test_invalid_values_are_rejected
    assert_raises(FaRuby::LayoutError) { build(base: -1) }
    assert_raises(FaRuby::LayoutError) { build(instances: 0) }
    assert_raises(FaRuby::LayoutError) { build(max_regs: 0) }
  end

  def test_device_name_is_configurable
    l = build(device_name: "D", base: 500)
    assert_equal "D500", l.device(l.vm_state_base)
    assert_equal "D500.L", l.device_long(l.vm_state_base)
  end

  # === 既定設定 ===

  def test_default_comes_from_faruby_default_yml
    l = Layout.default
    assert_equal "EM", l.device_name
    assert_operator l.base, :>=, 0
    assert_equal 2, l.instances
    assert_equal 80, l.max_regs
  end

  # 既定は何度呼んでも同じ (利用者設定に影響されない)
  def test_default_is_stable
    assert_equal Layout.default.instance_size, Layout.default.instance_size
    assert_same Layout.default, Layout.default
  end

  # === 設定ファイルの多層読み込み ===

  # faruby.yml に書いた項目だけが上書きされ、他は既定値が残る
  def test_user_config_overrides_only_specified_keys
    Dir.mktmpdir do |dir|
      path = File.join(dir, "faruby.yml")
      File.write(path, "memory:\n  base: 30000\n")

      config = FaRuby::Config.new(path)

      assert_equal 30_000, config.layout.base
      assert_equal 80,     config.layout.max_regs,     "指定していない項目は既定値のまま"
      assert_equal "EM",   config.layout.device_name
      assert_equal 50,     config.steps_per_cycle,     "memory 以外の節も既定値が残る"
    end
  end

  def test_user_config_can_override_plc_settings
    Dir.mktmpdir do |dir|
      path = File.join(dir, "faruby.yml")
      File.write(path, "plc:\n  host: 10.0.0.1\n")

      config = FaRuby::Config.new(path)

      assert_equal "10.0.0.1", config.plc_host
      assert_equal 8501,       config.plc_port, "指定していない項目は既定値のまま"
    end
  end

  # 既定値のみの設定は利用者設定を読まない
  def test_defaults_ignores_user_config
    config = FaRuby::Config.defaults
    assert_nil config.config_path
    assert_equal Layout.default.base, config.layout.base
  end

  # IP アドレスは既定値を持てないので、接続前に明確なエラーにする
  def test_missing_host_is_rejected_before_connecting
    config = FaRuby::Config.defaults
    err = assert_raises(FaRuby::ConfigError) { config.validate_connection! }
    assert_match(/plc\.host/, err.message)
  end

  # === 配置を変えても VM が動くこと ===

  # 領域をずらしても実行結果が変わらないことを確認する。
  # アドレス計算のどこかに固定値が残っていればここで落ちる。
  def test_vm_runs_identically_at_a_different_base
    bytecode = [
      0x09, 0x01,       # OP_LOADI_3 R[1]
      0x0A, 0x02,       # OP_LOADI_4 R[2]
      0x3C, 0x01,       # OP_ADD  R[1] = R[1] + R[2]
      0x69,             # OP_STOP
    ]

    results = [0, 20_000].map do |base|
      layout = build(base: base)
      sim = FaRuby::KvVmSimulator.new(layout: layout)
      em = sim.em
      em.write_u16(layout.pc_addr, 0)
      em.write_u16(layout.status_addr, VM_RUNNING)
      em.write_u16(layout.bytecode_len_addr, bytecode.size)
      em.write_u16(layout.nregs_addr, 4)
      bytecode.each_with_index { |b, i| em.write_u16(layout.bytecode_addr(i), b) }
      4.times { |i| em.write_s32(layout.reg_addr(i), 0) }
      sim.run
      [sim.status, sim.reg(1)]
    end

    assert_equal [VM_FINISHED, 7], results[0]
    assert_equal results[0], results[1], "base を変えると結果が変わってしまう"
  end

  # 生成される KV スクリプトが配置に追従すること
  #
  # 生成コードはブロック相対なので、base はインスタンスループの開始値と
  # Z の退避先に現れる。ブロック内のオフセットは base によらず同じ。
  def test_generated_script_follows_the_layout
    # 既定と必ず異なる base を使う (既定値を変えてもテストが壊れないように)
    layout = build(base: Layout.default.base + 12_345)
    source = FaRuby::KvsGenerator.new(layout: layout).source

    assert_includes source, "FOR Z#{FaRuby::KvsEmitter::Z_INSTANCE} = #{layout.base} "
    assert_includes source, "#{layout.device(layout.z_save_addr(1))} = Z1"
    # 既定配置のアドレスは現れない
    refute_includes source, "FOR Z#{FaRuby::KvsEmitter::Z_INSTANCE} = #{Layout.default.base} "
    refute_includes source, "#{Layout.default.device(Layout.default.z_save_addr(1))} = Z1"
  end
end
