# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/console/memory_transfer"

# MemoryTransfer のユニットテスト
# PLC 実機不要: モックアダプターを使用
class TestMemoryTransfer < Minitest::Test
  include FaRuby::VmConstants

# テストは既定レイアウト (faruby_default.yml) を使う。
# 利用者の faruby.yml に影響されないようにするため。
def layout
  FaRuby::MemoryLayout.default
end

  # モックアダプター (PLC の代わりにメモリ上で動作)
  class MockAdapter < FaRuby::Console::PlcAdapters::Base
    attr_reader :memory, :write_log

    def initialize
      @memory = Hash.new(0)
      @write_log = []  # [addr, values] の履歴
    end

    def connect; end
    def disconnect; end
    def connected?; true; end

    def read_word(addr)
      @memory[addr]
    end

    def write_word(addr, value)
      @memory[addr] = value
    end

    def read_words(addr, count)
      count.times.map { |i| @memory[addr + i] }
    end

    def write_words(addr, values)
      @write_log << [addr, values.dup]
      values.each_with_index do |v, i|
        @memory[addr + i] = v
      end
    end

    def device_name
      "EM"
    end
  end

  def setup
    @adapter = MockAdapter.new
    @transfer = FaRuby::Console::MemoryTransfer.new(@adapter)
  end

  # === group_consecutive テスト ===

  # 連続するアドレスはまとめて 1 回で転送される
  # アドレスは配置から導く (base が 0 とは限らないため)
  def test_write_image_groups_consecutive_addresses
    pc = layout.pc_addr           # VM 状態の先頭。次が STATUS
    far = layout.bytecode_base    # 離れた位置

    image = {
      pc => 10, pc + 1 => 20, pc + 2 => 30,   # 連続
      far => 70, far + 1 => 80,               # 離れた位置で連続
    }

    @transfer.write_image(image)

    # 2つのグループに分割されるはず
    assert_equal 2, @adapter.write_log.size

    # グループ1 (STATUS は STOPPED に上書きされる)
    assert_equal pc, @adapter.write_log[0][0]
    assert_equal [10, VM_STOPPED, 30], @adapter.write_log[0][1]

    # グループ2
    assert_equal far, @adapter.write_log[1][0]
    assert_equal [70, 80], @adapter.write_log[1][1]
  end

  def test_write_image_overrides_status_to_stopped
    image = { layout.status_addr => VM_RUNNING }

    @transfer.write_image(image)

    assert_equal VM_STOPPED, @adapter.memory[layout.status_addr]
  end

  def test_write_image_empty
    count = @transfer.write_image({})
    # 空でも STATUS=STOPPED が書き込まれる
    assert_equal 1, count
    assert_equal VM_STOPPED, @adapter.memory[layout.status_addr]
  end

  def test_write_image_returns_total_word_count
    pc = layout.pc_addr
    far = layout.bytecode_base
    image = { pc => 1, pc + 1 => 2, far => 3, far + 1 => 4, far + 2 => 5 }
    count = @transfer.write_image(image)
    assert_equal 5, count
  end

  # === read_vm_state テスト ===

  def test_read_vm_state
    @adapter.memory[layout.pc_addr] = 42
    @adapter.memory[layout.status_addr] = VM_FINISHED
    @adapter.memory[layout.error_addr] = 0
    @adapter.memory[layout.step_count_addr] = 100
    @adapter.memory[layout.step_count_addr + 1] = 0
    @adapter.memory[layout.steps_per_cycle_addr] = 50
    @adapter.memory[layout.bytecode_len_addr] = 20
    @adapter.memory[layout.nregs_addr] = 5
    @adapter.memory[layout.nlocals_addr] = 3

    state = @transfer.read_vm_state

    assert_equal 42, state[:pc]
    assert_equal VM_FINISHED, state[:status]
    assert_equal "完了", state[:status_label]
    assert_equal 0, state[:error]
    assert_equal 100, state[:step_count]
    assert_equal 50, state[:steps_per_cycle]
    assert_equal 20, state[:bytecode_len]
    assert_equal 5, state[:nregs]
    assert_equal 3, state[:nlocals]
  end

  def test_read_vm_state_error_status
    @adapter.memory[layout.status_addr] = VM_ERROR
    @adapter.memory[layout.error_addr] = 99

    state = @transfer.read_vm_state

    assert_equal VM_ERROR, state[:status]
    assert_equal "エラー", state[:status_label]
    assert_equal 99, state[:error]
  end

  # === read_registers テスト ===

  # レジスタスロット (4ワード) に値を書き込むヘルパー
  def write_reg_slot(index, lo, hi = 0, type = TT_EMPTY)
    @adapter.memory[layout.reg_type_addr(index)] = type
    addr = layout.reg_addr(index)
    @adapter.memory[addr] = lo
    @adapter.memory[addr + 1] = hi
  end

  def test_read_registers
    @adapter.memory[layout.nregs_addr] = 3
    @adapter.memory[layout.nlocals_addr] = 2

    write_reg_slot(0, 0)     # R[0] = 0 (self)
    write_reg_slot(1, 42)    # R[1] = 42 (local)
    write_reg_slot(2, 100)   # R[2] = 100 (temp)

    regs = @transfer.read_registers

    assert_equal 3, regs.size
    assert_equal [0, 42, 100], regs.map { |r| r[:value] }
    assert_equal %w[self local temp], regs.map { |r| r[:label] }
    assert_equal [TT_EMPTY] * 3, regs.map { |r| r[:type] }
  end

  # 表示は型タグに従う。値だけでは nil も false も 0 も見分けがつかない
  def test_registers_are_displayed_by_type
    @adapter.memory[layout.nregs_addr] = 5
    @adapter.memory[layout.nlocals_addr] = 5

    { 0 => [TT_NIL, 0], 1 => [TT_TRUE, 1], 2 => [TT_FALSE, 0],
      3 => [TT_INTEGER, 42], 4 => [TT_FLOAT, 0x3FC00000] }.each do |i, (tag, value)|
      @adapter.memory[layout.reg_type_addr(i)] = tag
      @adapter.memory[layout.reg_addr(i)]      = value & 0xFFFF
      @adapter.memory[layout.reg_addr(i) + 1]  = (value >> 16) & 0xFFFF
    end

    displays = @transfer.read_registers.map { |r| r[:display] }
    assert_equal ["nil", "true", "false", "42", "1.5"], displays
  end

  # スロット先頭の型タグが値と独立に読み出せること
  def test_read_registers_type_tag
    @adapter.memory[layout.nregs_addr] = 2
    @adapter.memory[layout.nlocals_addr] = 2

    write_reg_slot(0, 0)
    write_reg_slot(1, 42, 0, TT_INTEGER)

    regs = @transfer.read_registers

    assert_equal TT_INTEGER, regs[1][:type]
    assert_equal 42, regs[1][:value]
  end

  # 隣接スロットが値を侵食しないこと (ストライド 4 の確認)
  def test_read_registers_slots_are_independent
    @adapter.memory[layout.nregs_addr] = 2
    @adapter.memory[layout.nlocals_addr] = 2

    write_reg_slot(0, 0xFFFF, 0xFFFF)  # R[0] = -1
    write_reg_slot(1, 7)               # R[1] = 7

    regs = @transfer.read_registers

    assert_equal(-1, regs[0][:value])
    assert_equal 7, regs[1][:value]
  end

  def test_read_registers_negative_value
    @adapter.memory[layout.nregs_addr] = 2
    @adapter.memory[layout.nlocals_addr] = 2

    write_reg_slot(0, 0)
    write_reg_slot(1, 0xFFFF, 0xFFFF)  # R[1] = -1 (0xFFFFFFFF)

    regs = @transfer.read_registers

    assert_equal(-1, regs[1][:value])
  end

  def test_read_registers_32bit_value
    @adapter.memory[layout.nregs_addr] = 2
    @adapter.memory[layout.nlocals_addr] = 2

    write_reg_slot(0, 0)
    write_reg_slot(1, 0x86A0, 0x0001)  # R[1] = 100000 (0x000186A0)

    regs = @transfer.read_registers

    assert_equal 100000, regs[1][:value]
  end

  # === write_status テスト ===

  def test_write_status
    @transfer.write_status(VM_RUNNING)
    assert_equal VM_RUNNING, @adapter.memory[layout.status_addr]
  end

  # === request_reset テスト ===

  def test_request_reset
    @adapter.memory[layout.reset_req_addr] = 0

    @transfer.request_reset

    assert_equal 1, @adapter.memory[layout.reset_req_addr]
  end
end
