# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/memory_map"
require_relative "../simulator/em_memory"
require_relative "../simulator/kv_vm_simulator"

class TestVmSimulator < Minitest::Test
  include MrubycOnPlc::MemoryMap

  def setup
    @sim = MrubycOnPlc::KvVmSimulator.new
  end

  # EM メモリにバイトコードをセットして VM を起動するヘルパー
  def load_bytecode(bytecode, nlocals: 2, nregs: 4)
    em = @sim.em

    # VM 状態
    em.write_u16(PC_ADDR, 0)
    em.write_u16(STATUS_ADDR, VM_RUNNING)
    em.write_u16(ERROR_ADDR, 0)
    em.write_u16(STEPS_PER_CYCLE, 1000)
    em.write_u16(BYTECODE_LEN_ADDR, bytecode.size)
    em.write_u16(NREGS_ADDR, nregs)
    em.write_u16(NLOCALS_ADDR, nlocals)

    # バイトコード
    bytecode.each_with_index do |b, i|
      em.write_u16(BYTECODE_BASE + i, b)
    end

    # レジスタクリア
    nregs.times do |i|
      em.write_s32(MrubycOnPlc::MemoryMap.reg_addr(i), 0)
    end
  end

  # === OP_NOP ===
  def test_nop
    load_bytecode([
      0x00,             # OP_NOP
      0x69,             # OP_STOP
    ])
    @sim.run
    assert_equal VM_FINISHED, @sim.status
  end

  # === OP_LOADI_* (即値ロード) ===
  def test_loadi_3
    # R[1] = 3; STOP
    load_bytecode([
      0x09, 0x01,       # OP_LOADI_3 R[1]
      0x69,             # OP_STOP
    ])
    @sim.run
    assert_equal 3, @sim.reg(1)
    assert_equal VM_FINISHED, @sim.status
  end

  def test_loadi_0_through_7
    # R[1]=0, R[2]=1, ..., R[8]=7; STOP
    bytecode = []
    8.times do |i|
      bytecode << (0x06 + i)  # OP_LOADI_0 + i
      bytecode << (i + 1)     # register index
    end
    bytecode << 0x69  # OP_STOP

    load_bytecode(bytecode, nregs: 10)
    @sim.run

    8.times do |i|
      assert_equal i, @sim.reg(i + 1), "R[#{i + 1}] should be #{i}"
    end
  end

  def test_loadi_neg1
    # R[1] = -1; STOP
    load_bytecode([
      0x05, 0x01,       # OP_LOADI__1 R[1]
      0x69,             # OP_STOP
    ])
    @sim.run
    assert_equal(-1, @sim.reg(1))
  end

  # === OP_LOADI8 ===
  def test_loadi8_positive
    # R[1] = 42; STOP
    load_bytecode([
      0x03, 0x01, 42,   # OP_LOADI8 R[1], 42
      0x69,             # OP_STOP
    ])
    @sim.run
    assert_equal 42, @sim.reg(1)
  end

  def test_loadi8_negative
    # R[1] = -10; STOP  (256 - 10 = 246)
    load_bytecode([
      0x03, 0x01, 246,  # OP_LOADI8 R[1], -10 (signed byte)
      0x69,             # OP_STOP
    ])
    @sim.run
    assert_equal(-10, @sim.reg(1))
  end

  # === OP_LOADI16 ===
  def test_loadi16
    # R[1] = 1000; STOP  (0x03E8)
    load_bytecode([
      0x0E, 0x01, 0x03, 0xE8,  # OP_LOADI16 R[1], 1000
      0x69,                     # OP_STOP
    ])
    @sim.run
    assert_equal 1000, @sim.reg(1)
  end

  def test_loadi16_negative
    # R[1] = -500; STOP  (0xFE0C)
    load_bytecode([
      0x0E, 0x01, 0xFE, 0x0C,  # OP_LOADI16 R[1], -500
      0x69,                     # OP_STOP
    ])
    @sim.run
    assert_equal(-500, @sim.reg(1))
  end

  # === OP_MOVE ===
  def test_move
    # R[1] = 5; R[2] = R[1]; STOP
    load_bytecode([
      0x0B, 0x01,       # OP_LOADI_5 R[1]
      0x01, 0x02, 0x01, # OP_MOVE R[2], R[1]
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 5, @sim.reg(1)
    assert_equal 5, @sim.reg(2)
  end

  # === OP_ADD ===
  def test_add
    # R[1] = 3; R[2] = 4; R[1] = R[1] + R[2]; STOP
    load_bytecode([
      0x09, 0x01,       # OP_LOADI_3 R[1]
      0x0A, 0x02,       # OP_LOADI_4 R[2]
      0x3C, 0x01,       # OP_ADD R[1]  (R[1] = R[1] + R[2])
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 7, @sim.reg(1)
  end

  # === OP_ADDI ===
  def test_addi
    # R[1] = 3; R[1] = R[1] + 10; STOP
    load_bytecode([
      0x09, 0x01,       # OP_LOADI_3 R[1]
      0x3D, 0x01, 10,   # OP_ADDI R[1], 10
      0x69,             # OP_STOP
    ])
    @sim.run
    assert_equal 13, @sim.reg(1)
  end

  # === OP_SUB ===
  def test_sub
    # R[1] = 7; R[2] = 3; R[1] = R[1] - R[2]; STOP
    load_bytecode([
      0x0D, 0x01,       # OP_LOADI_7 R[1]
      0x09, 0x02,       # OP_LOADI_3 R[2]
      0x3E, 0x01,       # OP_SUB R[1]  (R[1] = R[1] - R[2])
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 4, @sim.reg(1)
  end

  # === OP_SUBI ===
  def test_subi
    # R[1] = 7; R[1] = R[1] - 2; STOP
    load_bytecode([
      0x0D, 0x01,       # OP_LOADI_7 R[1]
      0x3F, 0x01, 2,    # OP_SUBI R[1], 2
      0x69,             # OP_STOP
    ])
    @sim.run
    assert_equal 5, @sim.reg(1)
  end

  # === OP_MUL ===
  def test_mul
    # R[1] = 3; R[2] = 4; R[1] = R[1] * R[2]; STOP
    load_bytecode([
      0x09, 0x01,       # OP_LOADI_3 R[1]
      0x0A, 0x02,       # OP_LOADI_4 R[2]
      0x40, 0x01,       # OP_MUL R[1]  (R[1] = R[1] * R[2])
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 12, @sim.reg(1)
  end

  # === OP_DIV ===
  def test_div
    # R[1] = 7; R[2] = 2; R[1] = R[1] / R[2]; STOP
    load_bytecode([
      0x0D, 0x01,       # OP_LOADI_7 R[1]
      0x08, 0x02,       # OP_LOADI_2 R[2]
      0x41, 0x01,       # OP_DIV R[1]  (R[1] = R[1] / R[2])
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 3, @sim.reg(1)  # 7 / 2 = 3 (整数除算)
  end

  def test_div_by_zero
    # R[1] = 5; R[2] = 0; R[1] = R[1] / R[2]; STOP
    load_bytecode([
      0x0B, 0x01,       # OP_LOADI_5 R[1]
      0x06, 0x02,       # OP_LOADI_0 R[2]
      0x41, 0x01,       # OP_DIV R[1]
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal VM_ERROR, @sim.status
  end

  # === OP_RETURN ===
  def test_return_stops_at_toplevel
    load_bytecode([
      0x09, 0x01,       # OP_LOADI_3 R[1]
      0x38, 0x01,       # OP_RETURN R[1]
      0x06, 0x01,       # OP_LOADI_0 R[1] (should not execute)
    ])
    @sim.run
    assert_equal 3, @sim.reg(1)  # R[1] should still be 3
    assert_equal VM_FINISHED, @sim.status
  end

  # === 複合テスト: a = 1 + 2 ===
  # mrbc は定数畳み込みするかもしれないが、VM として正しく動くか
  def test_compound_add
    # a=R[1]; temp=R[2]
    # R[1] = 1; R[2] = 2; R[1] = R[1] + R[2]; RETURN
    load_bytecode([
      0x07, 0x01,       # OP_LOADI_1 R[1]
      0x08, 0x02,       # OP_LOADI_2 R[2]
      0x3C, 0x01,       # OP_ADD R[1]
      0x12, 0x03,       # OP_LOADSELF R[3]
      0x38, 0x03,       # OP_RETURN R[3]
    ], nlocals: 3, nregs: 5)
    @sim.run
    assert_equal 3, @sim.reg(1)
  end

  # === 複合テスト: a = 1 + 2; b = a * 3 ===
  def test_compound_arith
    # a=R[1], b=R[2], temps=R[3],R[4]
    # R[1] = 1; R[1] += 2 (ADDI); R[3] = R[1]; R[4] = 3; R[3] = R[3]*R[4]; R[2] = R[3]; STOP
    load_bytecode([
      0x07, 0x01,       # OP_LOADI_1 R[1]   -> R[1] = 1
      0x3D, 0x01, 0x02, # OP_ADDI R[1], 2   -> R[1] = 3
      0x01, 0x03, 0x01, # OP_MOVE R[3], R[1] -> R[3] = 3
      0x09, 0x04,       # OP_LOADI_3 R[4]   -> R[4] = 3
      0x40, 0x03,       # OP_MUL R[3]       -> R[3] = 3 * 3 = 9
      0x01, 0x02, 0x03, # OP_MOVE R[2], R[3] -> R[2] = 9
      0x69,             # OP_STOP
    ], nlocals: 3, nregs: 5)
    @sim.run
    assert_equal 3, @sim.reg(1), "a should be 3"
    assert_equal 9, @sim.reg(2), "b should be 9"
  end

  # === 複合テスト: x = 100; y = x - 37; z = y / 3 ===
  def test_compound_all_ops
    # x=R[1], y=R[2], z=R[3], temps=R[4],R[5]
    load_bytecode([
      0x03, 0x01, 100,  # OP_LOADI8 R[1], 100  -> x = 100
      0x01, 0x04, 0x01, # OP_MOVE R[4], R[1]   -> R[4] = 100
      0x3F, 0x04, 37,   # OP_SUBI R[4], 37     -> R[4] = 63
      0x01, 0x02, 0x04, # OP_MOVE R[2], R[4]   -> y = 63
      0x01, 0x04, 0x02, # OP_MOVE R[4], R[2]   -> R[4] = 63
      0x09, 0x05,       # OP_LOADI_3 R[5]      -> R[5] = 3
      0x41, 0x04,       # OP_DIV R[4]          -> R[4] = 63 / 3 = 21
      0x01, 0x03, 0x04, # OP_MOVE R[3], R[4]   -> z = 21
      0x69,             # OP_STOP
    ], nlocals: 4, nregs: 6)
    @sim.run
    assert_equal 100, @sim.reg(1), "x should be 100"
    assert_equal 63, @sim.reg(2), "y should be 63"
    assert_equal 21, @sim.reg(3), "z should be 21"
    assert_equal VM_FINISHED, @sim.status
  end

  # === OP_LOADINEG ===
  def test_loadineg
    # R[1] = -42; STOP
    load_bytecode([
      0x04, 0x01, 42,   # OP_LOADINEG R[1], 42 -> R[1] = -42
      0x69,             # OP_STOP
    ])
    @sim.run
    assert_equal(-42, @sim.reg(1))
  end

  # === 未知のオペコード ===
  def test_unknown_opcode_causes_error
    load_bytecode([
      0xFF,             # 未知のオペコード
    ])
    @sim.run
    assert_equal VM_ERROR, @sim.status
  end
end
