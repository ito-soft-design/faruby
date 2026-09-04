# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/config"
require_relative "../tools/mrb_parser"
require_relative "../tools/plc_codegen"
require_relative "../tools/console/memory_transfer"
require_relative "../tools/console/commands"
require_relative "test_memory_transfer"

# 複数インスタンスの操作
#
# インスタンスごとに別のプログラムが動くため、転送先・実行・状態読み取りが
# すべて選択中のインスタンスに向くことを確認する。
# PLC 実機不要 (test_memory_transfer.rb のモックアダプターを使う)。
class TestInstances < Minitest::Test
  include FaRuby::VmConstants

  MockAdapter = TestMemoryTransfer::MockAdapter

  INSTANCES = 3

  def setup
    @adapter = MockAdapter.new
    @config = StubConfig.new(FaRuby::MemoryLayout.new(base: 20_000, instances: INSTANCES))
    @transfer = FaRuby::Console::MemoryTransfer.new(@adapter, layout: @config.layout)
    @commands = FaRuby::Console::Commands.new(config: @config, adapter: @adapter, transfer: @transfer)
  end

  # Config のうちコンソールが使う部分だけを持つ差し替え
  class StubConfig
    attr_reader :layout, :config_path, :steps_per_cycle

    def initialize(layout)
      @layout = layout
      @config_path = nil
      @steps_per_cycle = 50
    end
  end

  def block(index) = @config.layout.for_instance(index)

  # === 既定と切り替え ===

  def test_starts_on_instance_zero
    assert_equal 0, @commands.instance
    assert_equal block(0).origin, @commands.layout.origin
  end

  def test_switching_moves_the_command_layout
    @commands.instance = 2
    assert_equal 2, @commands.instance
    assert_equal block(2).origin, @commands.layout.origin
  end

  # 転送側も一緒に切り替わらないと、状態は1番を見ながら2番へ書くことになる
  def test_switching_moves_the_transfer_layout
    @commands.instance = 1
    assert_equal block(1).origin, @transfer.layout.origin
  end

  def test_out_of_range_instance_is_rejected
    out, = capture_io { @commands.cmd_instance([INSTANCES.to_s]) }
    assert_match(/0-#{INSTANCES - 1}/, out)
    assert_equal 0, @commands.instance, "範囲外なら切り替わらない"
  end

  # === 書き込み先の分離 ===

  # 各インスタンスの STATUS は別のアドレス
  def test_run_and_stop_target_the_selected_instance
    @commands.instance = 1
    capture_io { @commands.cmd_run([]) }

    assert_equal VM_RUNNING, @adapter.read_word(block(1).status_addr)
    assert_equal 0, @adapter.read_word(block(0).status_addr), "他のインスタンスは動かさない"
    assert_equal 0, @adapter.read_word(block(2).status_addr)
  end

  def test_reset_targets_the_selected_instance
    @commands.instance = 2
    capture_io { @commands.cmd_reset([]) }

    assert_equal 1, @adapter.read_word(block(2).reset_req_addr)
    assert_equal 0, @adapter.read_word(block(0).reset_req_addr)
  end

  # バイトコードの転送先がインスタンスごとに分かれること。
  # ここが分かれていないと2つ目のプログラムが1つ目を上書きする。
  def test_programs_are_written_to_separate_blocks
    @commands.instance = 0
    @transfer.write_image(block(0).general_global_base => 0xAA)
    @commands.instance = 1
    @transfer.write_image(block(1).general_global_base => 0xBB)

    assert_equal 0xAA, @adapter.read_word(block(0).general_global_base)
    assert_equal 0xBB, @adapter.read_word(block(1).general_global_base)
  end

  # 固定領域 (FM) もインスタンスごとに分かれる
  #
  # ホストにはバンクを選ぶ手段が無いため ZF の絶対アドレスで書く。
  # 生成コードは FM のアドレスを VM 状態から引くので、両者がずれると
  # 別のインスタンスのバイトコードを実行してしまう。
  def test_fixed_areas_are_written_to_separate_blocks
    @commands.instance = 0
    @transfer.write_fixed_image(block(0).bytecode_base => 0xAA)
    @commands.instance = 1
    @transfer.write_fixed_image(block(1).bytecode_base => 0xBB)

    zf = @adapter.fixed
    assert_equal 0xAA, zf[block(0).fixed_host_addr(block(0).bytecode_base)]
    assert_equal 0xBB, zf[block(1).fixed_host_addr(block(1).bytecode_base)]
  end

  # 実行中の irep の位置は VM 状態にあり、インスタンスごとに違う。
  # 命令本体は 1 つしか無いため、ここがずれると全インスタンスが
  # インスタンス 0 のバイトコードを読む。
  def test_each_instance_points_at_its_own_fixed_area
    irep = FaRuby::Irep.new
    irep.nregs = 4
    irep.nlocals = 1
    irep.instructions = "\x69"
    irep.ilen = 1

    INSTANCES.times do |i|
      l = block(i)
      image = FaRuby::PlcCodegen.new(irep, layout: l).memory_image

      assert_equal l.irep_table_base, image[l.irep_table_addr_addr], "インスタンス #{i}"
      assert_equal l.bytecode_base, image[l.cur_bytecode_addr], "インスタンス #{i}"
      assert_equal l.device_table_base, image[l.cur_symbols_addr], "インスタンス #{i}"
    end
  end

  # 固定領域も重ならないこと
  def test_fixed_blocks_do_not_overlap
    ranges = INSTANCES.times.map do |i|
      l = block(i)
      (l.fixed_origin..(l.fixed_origin + l.fixed_instance_size - 1))
    end
    ranges.each_cons(2) do |a, b|
      assert_operator a.last, :<, b.first, "固定ブロックが重なっている"
    end
  end

  # 全インスタンス分がバンク 1 つ (32768 ワード) に収まること
  def test_fixed_areas_fit_in_one_bank
    assert_operator block(INSTANCES - 1).fixed_last_addr, :<,
                    FaRuby::MemoryLayout::FIXED_BANK_SIZE
  end

  # === 状態の読み取り ===

  def test_state_is_read_from_the_selected_instance
    @adapter.write_word(block(0).pc_addr, 11)
    @adapter.write_word(block(1).pc_addr, 22)

    @commands.instance = 1
    assert_equal 22, @transfer.read_vm_state[:pc]

    @commands.instance = 0
    assert_equal 11, @transfer.read_vm_state[:pc]
  end

  def test_registers_are_read_from_the_selected_instance
    @adapter.write_word(block(1).nregs_addr, 2)
    @adapter.write_word(block(1).reg_addr(1), 1234)

    @commands.instance = 1
    regs = @transfer.read_registers

    assert_equal 1234, regs[1][:value]
  end

  # === 配置 ===

  # ブロックが重ならないこと (重なると片方の実行が他方を壊す)
  def test_instance_blocks_do_not_overlap
    ranges = INSTANCES.times.map { |i| (block(i).origin..block(i).block_last_addr) }
    ranges.each_cons(2) do |a, b|
      assert_operator a.last, :<, b.first, "ブロックが重なっている"
    end
  end

  # Z の退避先は全インスタンス共通 (退避はインスタンスループの外で1回だけ)
  def test_z_save_area_is_shared_by_all_instances
    addrs = INSTANCES.times.map { |i| block(i).z_save_addr(1) }
    assert_equal 1, addrs.uniq.size
    assert_equal block(0).z_save_addr(1), addrs.first
  end
end
