# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../simulator/em_memory"
require_relative "../simulator/kv_vm_simulator"

class TestVmSimulator < Minitest::Test
  include FaRuby::VmConstants

# テストは既定レイアウト (faruby_default.yml) を使う。
# 利用者の faruby.yml に影響されないようにするため。
def layout
  FaRuby::MemoryLayout.default
end

  def setup
    @sim = FaRuby::KvVmSimulator.new
  end

  # EM メモリにバイトコードをセットして VM を起動するヘルパー
  def load_bytecode(bytecode, nlocals: 2, nregs: 4)
    em = @sim.em

    # VM 状態
    em.write_u16(layout.pc_addr, 0)
    em.write_u16(layout.status_addr, VM_RUNNING)
    em.write_u16(layout.error_addr, 0)
    em.write_u16(layout.steps_per_cycle_addr, 1000)
    em.write_u16(layout.bytecode_len_addr, bytecode.size)
    em.write_u16(layout.nregs_addr, nregs)
    em.write_u16(layout.nlocals_addr, nlocals)

    # バイトコード
    bytecode.each_with_index do |b, i|
      em.write_u16(layout.bytecode_base + i, b)
    end

    # レジスタクリア
    nregs.times do |i|
      em.write_s32(layout.reg_addr(i), 0)
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

  # === OP_LOADL (定数プール) ===
  def test_loadl
    # R[1] = Pool[0]; STOP
    load_bytecode([
      0x02, 0x01, 0x00, # OP_LOADL R[1], Pool[0]
      0x69,             # OP_STOP
    ])
    @sim.em.write_u16(layout.pool_type_addr(0), TT_INTEGER)
    @sim.em.write_s32(layout.pool_addr(0), 123456)
    @sim.run
    assert_equal 123456, @sim.reg(1)
  end

  # プールスロットは 4 ワード間隔で独立している (型タグが値を侵食しない)
  def test_loadl_slots_are_independent
    load_bytecode([
      0x02, 0x01, 0x00, # OP_LOADL R[1], Pool[0]
      0x02, 0x02, 0x01, # OP_LOADL R[2], Pool[1]
      0x69,             # OP_STOP
    ])
    @sim.em.write_u16(layout.pool_type_addr(0), TT_INTEGER)
    @sim.em.write_s32(layout.pool_addr(0), -1)
    @sim.em.write_u16(layout.pool_type_addr(1), TT_INTEGER)
    @sim.em.write_s32(layout.pool_addr(1), 222)
    @sim.run
    assert_equal(-1, @sim.reg(1))
    assert_equal 222, @sim.reg(2)
    # 型タグが -1 の上位ワードで潰されていないこと
    assert_equal TT_INTEGER, @sim.em.read_u16(layout.pool_type_addr(1))
  end

  # === 値スロットのレイアウト (ストライド 4) ===
  def test_register_slot_layout
    # R[1] = 100000 (32ビット値), R[2] = 1
    load_bytecode([
      0x0F, 0x01, 0x00, 0x01, 0x86, 0xA0, # OP_LOADI32 R[1], 100000
      0x07, 0x02,                          # OP_LOADI_1 R[2]
      0x69,                                # OP_STOP
    ])
    @sim.run

    # 32ビット値は値ワード (スロット先頭+1) に格納される
    assert_equal 100000, @sim.em.read_s32(layout.reg_addr(1))
    # 隣接スロットが侵食されない
    assert_equal 1, @sim.reg(2)
    # スロット先頭に型タグが入る
    assert_equal TT_INTEGER, @sim.em.read_u16(layout.reg_type_addr(1))
    assert_equal TT_INTEGER, @sim.em.read_u16(layout.reg_type_addr(2))
    # スロット間隔が SLOT_WORDS であること
    assert_equal SLOT_WORDS,
                 layout.reg_slot_addr(2) - layout.reg_slot_addr(1)
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

  # === OP_LOADTRUE / OP_LOADFALSE ===
  def test_loadtrue
    load_bytecode([
      0x13, 0x01,       # OP_LOADTRUE R[1]
      0x69,             # OP_STOP
    ])
    @sim.run
    assert_equal 1, @sim.reg(1)
  end

  def test_loadfalse
    load_bytecode([
      0x14, 0x01,       # OP_LOADFALSE R[1]
      0x69,             # OP_STOP
    ])
    @sim.run
    assert_equal 0, @sim.reg(1)
  end

  # === OP_EQ ===
  def test_eq_true
    load_bytecode([
      0x09, 0x01,       # OP_LOADI_3 R[1]
      0x09, 0x02,       # OP_LOADI_3 R[2]
      0x42, 0x01,       # OP_EQ R[1]  (R[1] == R[2])
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 1, @sim.reg(1)
  end

  def test_eq_false
    load_bytecode([
      0x09, 0x01,       # OP_LOADI_3 R[1]
      0x0A, 0x02,       # OP_LOADI_4 R[2]
      0x42, 0x01,       # OP_EQ R[1]  (R[1] == R[2])
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 0, @sim.reg(1)
  end

  # === OP_LT ===
  def test_lt_true
    load_bytecode([
      0x09, 0x01,       # OP_LOADI_3 R[1]  (3)
      0x0A, 0x02,       # OP_LOADI_4 R[2]  (4)
      0x43, 0x01,       # OP_LT R[1]  (3 < 4)
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 1, @sim.reg(1)
  end

  def test_lt_false
    load_bytecode([
      0x0A, 0x01,       # OP_LOADI_4 R[1]  (4)
      0x09, 0x02,       # OP_LOADI_3 R[2]  (3)
      0x43, 0x01,       # OP_LT R[1]  (4 < 3)
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 0, @sim.reg(1)
  end

  # === OP_LE ===
  def test_le_true
    load_bytecode([
      0x09, 0x01,       # OP_LOADI_3 R[1]  (3)
      0x0A, 0x02,       # OP_LOADI_4 R[2]  (4)
      0x44, 0x01,       # OP_LE R[1]  (3 <= 4)
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 1, @sim.reg(1)
  end

  def test_le_equal
    load_bytecode([
      0x09, 0x01,       # OP_LOADI_3 R[1]  (3)
      0x09, 0x02,       # OP_LOADI_3 R[2]  (3)
      0x44, 0x01,       # OP_LE R[1]  (3 <= 3)
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 1, @sim.reg(1)
  end

  def test_le_false
    load_bytecode([
      0x0A, 0x01,       # OP_LOADI_4 R[1]  (4)
      0x09, 0x02,       # OP_LOADI_3 R[2]  (3)
      0x44, 0x01,       # OP_LE R[1]  (4 <= 3)
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 0, @sim.reg(1)
  end

  # === OP_GT ===
  def test_gt_true
    load_bytecode([
      0x0A, 0x01,       # OP_LOADI_4 R[1]  (4)
      0x09, 0x02,       # OP_LOADI_3 R[2]  (3)
      0x45, 0x01,       # OP_GT R[1]  (4 > 3)
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 1, @sim.reg(1)
  end

  # === OP_GE ===
  def test_ge_true
    load_bytecode([
      0x09, 0x01,       # OP_LOADI_3 R[1]  (3)
      0x09, 0x02,       # OP_LOADI_3 R[2]  (3)
      0x46, 0x01,       # OP_GE R[1]  (3 >= 3)
      0x69,             # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 1, @sim.reg(1)
  end

  # === OP_JMP ===
  def test_jmp_forward
    # JMP で OP_LOADI_0 をスキップ
    # JMP at offset 2: after reading S operand → PC=5
    # offset=2 → target=5+2=7 (OP_STOP)
    load_bytecode([
      0x0B, 0x01,       # 0,1: OP_LOADI_5 R[1]
      0x25, 0x00, 0x02, # 2,3,4: OP_JMP offset=2 → PC=5+2=7
      0x06, 0x01,       # 5,6: OP_LOADI_0 R[1] (skipped)
      0x69,             # 7: OP_STOP
    ])
    @sim.run
    assert_equal 5, @sim.reg(1), "LOADI_0 should be skipped"
    assert_equal VM_FINISHED, @sim.status
  end

  # === OP_JMPNOT ===
  #
  # 真偽判定は型タグで行う。Ruby で偽なのは nil と false だけ。
  def test_jmpnot_taken
    # R[1]=false, JMPNOT should jump
    # JMPNOT at offset 2: after reading BS operands → PC=6
    # offset=2 → target=6+2=8 (OP_STOP)
    load_bytecode([
      0x14, 0x01,             # 0,1: OP_LOADFALSE R[1]
      0x27, 0x01, 0x00, 0x02, # 2,3,4,5: OP_JMPNOT R[1], offset=2 → PC=6+2=8
      0x0B, 0x02,             # 6,7: OP_LOADI_5 R[2] (skipped)
      0x69,                   # 8: OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 0, @sim.reg(2), "LOADI_5 should be skipped"
  end

  def test_jmpnot_taken_for_nil
    load_bytecode([
      0x11, 0x01,             # OP_LOADNIL R[1]
      0x27, 0x01, 0x00, 0x02, # OP_JMPNOT R[1] → 飛ぶ
      0x0B, 0x02,             # OP_LOADI_5 R[2] (skipped)
      0x69,                   # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 0, @sim.reg(2), "nil は偽なので飛ぶ"
  end

  # Ruby では 0 も真。値ではなく型タグで判定していることの確認
  def test_integer_zero_is_truthy
    load_bytecode([
      0x06, 0x01,             # OP_LOADI_0 R[1] (整数の 0)
      0x27, 0x01, 0x00, 0x02, # OP_JMPNOT R[1] → 飛ばない
      0x0B, 0x02,             # OP_LOADI_5 R[2] (executed)
      0x69,                   # OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 5, @sim.reg(2), "整数の 0 は Ruby では真"
  end

  def test_jmpnot_not_taken
    # R[1]=1 (true), JMPNOT should NOT jump
    load_bytecode([
      0x07, 0x01,             # 0,1: OP_LOADI_1 R[1] (true)
      0x27, 0x01, 0x00, 0x02, # 2,3,4,5: OP_JMPNOT R[1], offset=2 → not taken
      0x0B, 0x02,             # 6,7: OP_LOADI_5 R[2] (executed)
      0x69,                   # 8: OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 5, @sim.reg(2), "LOADI_5 should execute"
  end

  # === OP_JMPIF ===
  def test_jmpif_taken
    # R[1]=1 (true), JMPIF should jump
    # JMPIF at offset 2: after reading BS operands → PC=6
    # offset=2 → target=6+2=8 (OP_STOP)
    load_bytecode([
      0x07, 0x01,             # 0,1: OP_LOADI_1 R[1]
      0x26, 0x01, 0x00, 0x02, # 2,3,4,5: OP_JMPIF R[1], offset=2 → PC=6+2=8
      0x0B, 0x02,             # 6,7: OP_LOADI_5 R[2] (skipped)
      0x69,                   # 8: OP_STOP
    ], nregs: 4)
    @sim.run
    assert_equal 0, @sim.reg(2), "LOADI_5 should be skipped"
  end

  # === While ループ (後方ジャンプ) ===
  def test_while_loop
    # i = 0; while i < 3 do i = i + 1 end
    # Expected: i=3
    #
    # Bytecode layout:
    #  0,1:       OP_LOADI_0 R[1]       ; i = 0
    #  2,3,4:     OP_JMP offset=4       ; PC=5+4=9 → condition
    #  -- body: --
    #  5,6,7:     OP_ADDI R[1], 1       ; i += 1
    #  8:         OP_NOP (padding)
    #  -- condition: --
    #  9,10,11:   OP_MOVE R[2], R[1]    ; R[2] = i
    #  12,13:     OP_LOADI_3 R[3]       ; R[3] = 3
    #  14,15:     OP_LT R[2]           ; R[2] = (i < 3)
    #  16,17,18,19: OP_JMPIF R[2], offset=-15 ; PC=20+(-15)=5 → body
    #  20:        OP_STOP
    offset_back = -15
    offset_u16 = offset_back & 0xFFFF  # 0xFFF1
    hi = (offset_u16 >> 8) & 0xFF     # 0xFF
    lo = offset_u16 & 0xFF            # 0xF1

    load_bytecode([
      0x06, 0x01,             #  0,1:     OP_LOADI_0 R[1]       ; i = 0
      0x25, 0x00, 0x04,       #  2,3,4:   OP_JMP offset=4       ; PC=5+4=9
      0x3D, 0x01, 0x01,       #  5,6,7:   OP_ADDI R[1], 1       ; i += 1
      0x00,                   #  8:       OP_NOP (padding)
      0x01, 0x02, 0x01,       #  9,10,11: OP_MOVE R[2], R[1]    ; R[2] = i
      0x09, 0x03,             # 12,13:    OP_LOADI_3 R[3]       ; R[3] = 3
      0x43, 0x02,             # 14,15:    OP_LT R[2]            ; R[2] = (i < 3)
      0x26, 0x02, hi, lo,    # 16,17,18,19: OP_JMPIF R[2], offset=-15 → PC=5
      0x69,                   # 20:       OP_STOP
    ], nregs: 5)
    @sim.run
    assert_equal 3, @sim.reg(1), "i should be 3 after while loop"
    assert_equal VM_FINISHED, @sim.status
  end

  # === OP_GETGV / OP_SETGV ===

  # デバイスマッピングテーブルにエントリを設定するヘルパー
  def setup_device_mapping(sym_index, device_type, device_addr)
    table_addr = layout.device_table_base + sym_index * DEVICE_TABLE_STRIDE
    @sim.em.write_u16(table_addr, device_type)
    @sim.em.write_u16(table_addr + 1, device_addr)
  end

  def test_setgv_em
    # OP_SETGV: R[1] を EM6000 に書き込み
    load_bytecode([
      0x03, 0x01, 42,   # OP_LOADI8 R[1], 42
      0x16, 0x01, 0x00, # OP_SETGV R[1], sym[0]
      0x69,             # OP_STOP
    ])
    setup_device_mapping(0, DEVICE_TYPE_EM, 6000)
    @sim.run
    assert_equal VM_FINISHED, @sim.status
    assert_equal 42, @sim.em.read_s32(6000)
  end

  def test_getgv_em
    # OP_GETGV: EM6000 の値を R[1] に読み取り
    load_bytecode([
      0x15, 0x01, 0x00, # OP_GETGV R[1], sym[0]
      0x69,             # OP_STOP
    ])
    setup_device_mapping(0, DEVICE_TYPE_EM, 6000)
    @sim.em.write_s32(6000, 99)
    @sim.run
    assert_equal VM_FINISHED, @sim.status
    assert_equal 99, @sim.reg(1)
  end

  def test_setgv_getgv_combined
    # 書き込み後、レジスタをクリアして読み戻し
    load_bytecode([
      0x03, 0x01, 42,   # OP_LOADI8 R[1], 42
      0x16, 0x01, 0x00, # OP_SETGV R[1], sym[0]
      0x06, 0x01,       # OP_LOADI_0 R[1]  (clear)
      0x15, 0x01, 0x00, # OP_GETGV R[1], sym[0]
      0x69,             # OP_STOP
    ])
    setup_device_mapping(0, DEVICE_TYPE_EM, 6000)
    @sim.run
    assert_equal VM_FINISHED, @sim.status
    assert_equal 42, @sim.reg(1)
  end

  def test_getgv_dm
    # DM デバイスからの読み取り
    load_bytecode([
      0x15, 0x01, 0x00, # OP_GETGV R[1], sym[0]
      0x69,             # OP_STOP
    ])
    setup_device_mapping(0, DEVICE_TYPE_DM, 100)
    @sim.devices[DEVICE_TYPE_DM].write_s32(100, 77)
    @sim.run
    assert_equal VM_FINISHED, @sim.status
    assert_equal 77, @sim.reg(1)
  end

  def test_setgv_dm
    # DM デバイスへの書き込み
    load_bytecode([
      0x03, 0x01, 55,   # OP_LOADI8 R[1], 55
      0x16, 0x01, 0x00, # OP_SETGV R[1], sym[0]
      0x69,             # OP_STOP
    ])
    setup_device_mapping(0, DEVICE_TYPE_DM, 200)
    @sim.run
    assert_equal VM_FINISHED, @sim.status
    assert_equal 55, @sim.devices[DEVICE_TYPE_DM].read_s32(200)
  end

  def test_getgv_negative_value
    # 負の値の読み取り
    load_bytecode([
      0x15, 0x01, 0x00, # OP_GETGV R[1], sym[0]
      0x69,             # OP_STOP
    ])
    setup_device_mapping(0, DEVICE_TYPE_EM, 6000)
    @sim.em.write_s32(6000, -100)
    @sim.run
    assert_equal VM_FINISHED, @sim.status
    assert_equal(-100, @sim.reg(1))
  end

  # --- ビットデバイステスト ---

  def test_setgv_bit_device_clamps_to_1
    # ビットデバイス (MR) への書き込みは非0→1になる
    load_bytecode([
      0x03, 0x01, 42,   # OP_LOADI8 R[1], 42
      0x16, 0x01, 0x00, # OP_SETGV R[1], sym[0]
      0x69,             # OP_STOP
    ])
    setup_device_mapping(0, DEVICE_TYPE_MR, 10)
    @sim.run
    assert_equal VM_FINISHED, @sim.status
    assert_equal 1, @sim.devices[DEVICE_TYPE_MR].read_u16(10)
  end

  def test_setgv_bit_device_zero
    # ビットデバイス (R) への 0 の書き込み
    load_bytecode([
      0x06, 0x01,       # OP_LOADI_0 R[1], 0
      0x16, 0x01, 0x00, # OP_SETGV R[1], sym[0]
      0x69,             # OP_STOP
    ])
    setup_device_mapping(0, DEVICE_TYPE_R, 200)
    @sim.run
    assert_equal VM_FINISHED, @sim.status
    assert_equal 0, @sim.devices[DEVICE_TYPE_R].read_u16(200)
  end

  def test_getgv_bit_device_returns_0_or_1
    # ビットデバイス (MR) からの読み取りは 0 or 1
    load_bytecode([
      0x15, 0x01, 0x00, # OP_GETGV R[1], sym[0]
      0x69,             # OP_STOP
    ])
    setup_device_mapping(0, DEVICE_TYPE_MR, 5)
    @sim.devices[DEVICE_TYPE_MR].write_u16(5, 1)
    @sim.run
    assert_equal VM_FINISHED, @sim.status
    assert_equal 1, @sim.reg(1)
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
