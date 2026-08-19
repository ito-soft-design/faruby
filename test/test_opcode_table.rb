# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/opcode_table"
require_relative "../tools/kvs_generator"
require_relative "../tools/disasm"
require_relative "../simulator/em_memory"
require_relative "../simulator/sim_vm"

# オペコード定義表のテスト
#
# 命令の意味は tools/opcode_table.rb に一本化されており、
# PLC 側 (vm_core.kvs) とシミュレータ (SimVm) は同じ定義から導かれます。
# 以前は両者を突き合わせる test_vm_core_parity.rb が必要でしたが、
# 情報源が1つになったため構造的に食い違わなくなりました。
class TestOpcodeTable < Minitest::Test
  Table = MrubycOnPlc::OpcodeTable

  # === 定義表の健全性 ===

  def test_mruby_opcodes_have_unique_names
    names = Table::MRUBY_OPCODES.values.map(&:first)
    duplicates = names.tally.select { |_, n| n > 1 }.keys
    assert_empty duplicates, "重複した命令名: #{duplicates.inspect}"
  end

  def test_every_format_has_operand_sizes
    formats = Table::MRUBY_OPCODES.values.map(&:last).uniq
    missing = formats - Table::FORMAT_OPERANDS.keys
    assert_empty missing, "オペランド定義の無い命令形式: #{missing.inspect}"
  end

  def test_format_sizes_match_operand_sizes
    Table::FORMAT_OPERANDS.each do |fmt, sizes|
      assert_equal sizes.sum, Table::FORMAT_SIZES.fetch(fmt), "#{fmt} のバイト数"
    end
  end

  # 実装済み命令は mruby のオペコード表に含まれる
  # (OpcodeDef が MRUBY_OPCODES を引くので取り違えは起きないが、念のため)
  def test_implemented_opcodes_are_known
    unknown = Table.codes - Table::MRUBY_OPCODES.keys
    assert_empty unknown, "mruby に存在しないオペコード: #{unknown.inspect}"
  end

  def test_implemented_opcodes_have_no_duplicates
    assert_equal Table.codes.uniq, Table.codes
  end

  # 命令名と形式は定義表から自動で引かれる
  def test_name_and_format_come_from_mruby_table
    Table.all.each do |op|
      expected_name, expected_format = Table::MRUBY_OPCODES.fetch(op.code)
      assert_equal expected_name, op.name
      assert_equal expected_format, op.format
    end
  end

  def test_unknown_opcode_is_rejected
    assert_raises(ArgumentError) { MrubycOnPlc::OpcodeDef.new(0xFF, "存在しない命令") }
  end

  # === 逆アセンブラとの共有 ===

  def test_disassembler_uses_the_shared_table
    assert_same Table::MRUBY_OPCODES, MrubycOnPlc::Disassembler::OPCODES
    assert_same Table::FORMAT_SIZES, MrubycOnPlc::Disassembler::FORMAT_SIZES
  end

  # === 両バックエンドが同じ定義を解釈できる ===

  # 命令本体が片方のバックエンドにしかない操作を使っていないことを確認する。
  # これが通れば「PLC では動くがシミュレータでは動かない」命令は存在しない。
  def test_every_opcode_runs_on_both_backends
    Table.all.each do |op|
      emit_with_kvs(op)
      execute_with_sim(op)
    end
  end

  # KV 側は必ず何らかのコードを出力する (OP_NOP を除く)
  def test_kvs_backend_emits_code_for_each_opcode
    Table.all.each do |op|
      next if op.name == :OP_NOP

      lines = emit_with_kvs(op)
      code = lines.reject { |l| l.strip.empty? || l.strip.start_with?("'") }
      refute_empty code, "#{op.name} が何も出力していない"
    end
  end

  private

  def emit_with_kvs(op)
    e = MrubycOnPlc::KvsEmitter.new
    e.begin_instruction
    e.fetch_operands(op.operand_sizes)
    op.body&.call(e)
    e.lines
  rescue NoMethodError => err
    flunk "#{op.name}: KvsEmitter に #{err.name} がありません"
  end

  def execute_with_sim(op)
    em = MrubycOnPlc::EmMemory.new
    devices = Array.new(10) { MrubycOnPlc::EmMemory.new }
    devices[0] = em
    vm = MrubycOnPlc::SimVm.new(em, devices)
    vm.begin_instruction({ a: 1, b: 1, c: 1 })
    op.body&.call(vm)
  rescue NoMethodError => err
    flunk "#{op.name}: SimVm に #{err.name} がありません"
  end
end
