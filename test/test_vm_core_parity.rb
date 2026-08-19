# frozen_string_literal: true

require "minitest/autorun"

# PLC 側 VM (vm_core.kvs) と シミュレータ (kv_vm_simulator.rb) の
# 対応オペコードが一致していることを検証します。
#
# 片方にしか実装がないと、シミュレータでは通るのに実機で
# 「未知のオペコード」エラーになる (逆も然り)。実機で踏むまで
# 気づけないため、ソースを突き合わせて検出します。
class TestVmCoreParity < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  KVS_PATH = File.join(ROOT, "plc/keyence/vm_core.kvs")
  SIM_PATH = File.join(ROOT, "simulator/kv_vm_simulator.rb")

  # vm_core.kvs の "IF EM6 = N THEN" からオペコードを抽出
  def kvs_opcodes
    File.read(KVS_PATH).scan(/IF\s+EM6\s*=\s*(\d+)\s+THEN/).flatten.map(&:to_i).sort.uniq
  end

  # kv_vm_simulator.rb の "when 0xNN" / "when 0xNN..0xMM" からオペコードを抽出
  def sim_opcodes
    src = File.read(SIM_PATH)
    ops = []
    src.scan(/^\s*when\s+(0x[0-9A-Fa-f]+)(?:\.\.(0x[0-9A-Fa-f]+))?/) do |lo, hi|
      lo = Integer(lo, 16)
      ops.concat(hi ? (lo..Integer(hi, 16)).to_a : [lo])
    end
    ops.sort.uniq
  end

  def hex(ops)
    ops.map { |o| format("0x%02X", o) }
  end

  def test_sources_are_parseable
    refute_empty kvs_opcodes, "vm_core.kvs からオペコードを抽出できない (書式が変わった?)"
    refute_empty sim_opcodes, "kv_vm_simulator.rb からオペコードを抽出できない (書式が変わった?)"
  end

  def test_opcode_coverage_matches
    kvs = kvs_opcodes
    sim = sim_opcodes

    only_kvs = kvs - sim
    only_sim = sim - kvs

    assert_empty hex(only_sim),
                 "シミュレータにのみ実装されているオペコード " \
                 "(実機で「未知のオペコード」エラーになる): #{hex(only_sim).join(', ')}"
    assert_empty hex(only_kvs),
                 "vm_core.kvs にのみ実装されているオペコード " \
                 "(シミュレータで検証できない): #{hex(only_kvs).join(', ')}"
  end
end
