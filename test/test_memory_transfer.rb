# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/memory_map"
require_relative "../tools/console/memory_transfer"

# MemoryTransfer のユニットテスト
# PLC 実機不要: モックアダプターを使用
class TestMemoryTransfer < Minitest::Test
  include MrubycOnPlc::MemoryMap

  # モックアダプター (PLC の代わりにメモリ上で動作)
  class MockAdapter < MrubycOnPlc::Console::PlcAdapters::Base
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
    @transfer = MrubycOnPlc::Console::MemoryTransfer.new(@adapter)
  end

  # === group_consecutive テスト ===

  def test_write_image_groups_consecutive_addresses
    image = {
      0 => 10, 1 => 20, 2 => 30,           # EM0-EM2 (連続)
      100 => 40, 101 => 50, 102 => 60,      # EM100-EM102 (連続)
      1000 => 70, 1001 => 80,               # EM1000-EM1001 (連続)
    }

    @transfer.write_image(image)

    # 3つのグループに分割されるはず
    assert_equal 3, @adapter.write_log.size

    # グループ1: EM0-EM2 (STATUS は STOPPED に上書き)
    assert_equal 0, @adapter.write_log[0][0]
    assert_equal [10, VM_STOPPED, 30], @adapter.write_log[0][1]

    # グループ2: EM100-EM102
    assert_equal 100, @adapter.write_log[1][0]
    assert_equal [40, 50, 60], @adapter.write_log[1][1]

    # グループ3: EM1000-EM1001
    assert_equal 1000, @adapter.write_log[2][0]
    assert_equal [70, 80], @adapter.write_log[2][1]
  end

  def test_write_image_overrides_status_to_stopped
    image = { STATUS_ADDR => VM_RUNNING }

    @transfer.write_image(image)

    assert_equal VM_STOPPED, @adapter.memory[STATUS_ADDR]
  end

  def test_write_image_empty
    count = @transfer.write_image({})
    # 空でも STATUS=STOPPED が書き込まれる
    assert_equal 1, count
    assert_equal VM_STOPPED, @adapter.memory[STATUS_ADDR]
  end

  def test_write_image_returns_total_word_count
    image = { 0 => 1, 1 => 2, 100 => 3, 101 => 4, 102 => 5 }
    count = @transfer.write_image(image)
    assert_equal 5, count
  end

  # === read_vm_state テスト ===

  def test_read_vm_state
    @adapter.memory[PC_ADDR] = 42
    @adapter.memory[STATUS_ADDR] = VM_FINISHED
    @adapter.memory[ERROR_ADDR] = 0
    @adapter.memory[STEP_COUNT_ADDR] = 100
    @adapter.memory[STEP_COUNT_ADDR + 1] = 0
    @adapter.memory[STEPS_PER_CYCLE] = 50
    @adapter.memory[BYTECODE_LEN_ADDR] = 20
    @adapter.memory[NREGS_ADDR] = 5
    @adapter.memory[NLOCALS_ADDR] = 3

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
    @adapter.memory[STATUS_ADDR] = VM_ERROR
    @adapter.memory[ERROR_ADDR] = 99

    state = @transfer.read_vm_state

    assert_equal VM_ERROR, state[:status]
    assert_equal "エラー", state[:status_label]
    assert_equal 99, state[:error]
  end

  # === read_registers テスト ===

  def test_read_registers
    @adapter.memory[NREGS_ADDR] = 3
    @adapter.memory[NLOCALS_ADDR] = 2

    # R[0] = 0 (self)
    @adapter.memory[REG_FILE_BASE] = 0
    @adapter.memory[REG_FILE_BASE + 1] = 0

    # R[1] = 42 (local)
    @adapter.memory[REG_FILE_BASE + 2] = 42
    @adapter.memory[REG_FILE_BASE + 3] = 0

    # R[2] = 100 (temp)
    @adapter.memory[REG_FILE_BASE + 4] = 100
    @adapter.memory[REG_FILE_BASE + 5] = 0

    regs = @transfer.read_registers

    assert_equal 3, regs.size
    assert_equal({ index: 0, value: 0, label: "self" }, regs[0])
    assert_equal({ index: 1, value: 42, label: "local" }, regs[1])
    assert_equal({ index: 2, value: 100, label: "temp" }, regs[2])
  end

  def test_read_registers_negative_value
    @adapter.memory[NREGS_ADDR] = 2
    @adapter.memory[NLOCALS_ADDR] = 2

    # R[0] = 0
    @adapter.memory[REG_FILE_BASE] = 0
    @adapter.memory[REG_FILE_BASE + 1] = 0

    # R[1] = -1 (0xFFFFFFFF)
    @adapter.memory[REG_FILE_BASE + 2] = 0xFFFF
    @adapter.memory[REG_FILE_BASE + 3] = 0xFFFF

    regs = @transfer.read_registers

    assert_equal(-1, regs[1][:value])
  end

  def test_read_registers_32bit_value
    @adapter.memory[NREGS_ADDR] = 2
    @adapter.memory[NLOCALS_ADDR] = 2

    # R[0] = 0
    @adapter.memory[REG_FILE_BASE] = 0
    @adapter.memory[REG_FILE_BASE + 1] = 0

    # R[1] = 100000 (0x000186A0)
    @adapter.memory[REG_FILE_BASE + 2] = 0x86A0  # lo
    @adapter.memory[REG_FILE_BASE + 3] = 0x0001  # hi

    regs = @transfer.read_registers

    assert_equal 100000, regs[1][:value]
  end

  # === write_status テスト ===

  def test_write_status
    @transfer.write_status(VM_RUNNING)
    assert_equal VM_RUNNING, @adapter.memory[STATUS_ADDR]
  end

  # === reset_vm テスト ===

  def test_reset_vm
    @adapter.memory[PC_ADDR] = 50
    @adapter.memory[STATUS_ADDR] = VM_ERROR
    @adapter.memory[ERROR_ADDR] = 99

    @transfer.reset_vm(steps_per_cycle: 100)

    assert_equal 0, @adapter.memory[PC_ADDR]
    assert_equal VM_STOPPED, @adapter.memory[STATUS_ADDR]
    assert_equal 0, @adapter.memory[ERROR_ADDR]
    assert_equal 100, @adapter.memory[STEPS_PER_CYCLE]
  end
end
