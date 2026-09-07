# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/opcode_table"

# ドキュメントが実装とずれていないか
#
# 文章は動かないので、放っておくと**古いまま残ります**。数を書いた箇所や
# 一覧は実装から引けるので、ここで突き合わせておきます。
#
# 説明そのものは検査できません。数と項目の抜けだけを見ます。
class TestDocs < Minitest::Test
  include FaRuby::VmConstants

  Layout = FaRuby::MemoryLayout

  def doc(name)
    File.read(File.expand_path("../#{name}", __dir__), encoding: "utf-8")
  end

  # === 対応オペコード一覧 ===

  def test_the_opcode_count_matches
    assert_includes doc("doc/opcodes.md"),
                    "実装済みは #{FaRuby::OpcodeTable.codes.size} 命令です"
  end

  # 表に載っていない命令があると、利用者は使えることに気づけない
  def test_every_opcode_is_in_the_table
    text = doc("doc/opcodes.md")
    missing = FaRuby::OpcodeTable.codes.reject do |code|
      text.include?(format("| 0x%02X | %d |", code, code))
    end

    assert_empty missing.map { |code| format("0x%02X", code) }, "一覧に無い命令"
  end

  # === VM 状態領域 ===

  def test_the_vm_state_size_matches
    assert_includes doc("doc/architecture.md"),
                    "ブロック先頭から #{Layout::VM_STATE_WORDS} ワード"
  end

  # オフセットの表に漏れがあると、空きを探すときに衝突する
  def test_every_vm_state_offset_is_in_the_table
    table = doc("doc/architecture.md")[/^\| オフセット \|.*\n\|[-| ]+\|\n((?:\| \+.*\n)+)/, 1]
    refute_nil table, "VM 状態領域の表が見つからない"

    covered = table.scan(/^\| \+(\d+)(?:-(\d+))?/).flat_map do |first, last|
      (first.to_i..(last || first).to_i).to_a
    end
    offsets = Layout.constants.grep(/^OFFSET_/).map { |name| Layout.const_get(name) }

    assert_empty offsets.uniq.sort - covered, "表に無いオフセット"
  end

  # === 型タグ ===

  # 表に無いタグがあると、値ワードの読み方が分からないまま放置される
  def test_every_type_tag_is_in_the_table
    text = doc("doc/architecture.md")
    tags = FaRuby::VmConstants.constants.grep(/^TT_/)
                              .reject { |name| name.to_s =~ /FALSY|CANONICAL|NAMES/ }
    missing = tags.reject do |name|
      text.include?("| #{name} | #{FaRuby::VmConstants.const_get(name)} |")
    end

    assert_empty missing, "型タグの表に無いもの"
  end

  # === ロードマップ ===

  def test_the_roadmap_opcode_count_matches
    assert_includes doc("doc/roadmap.md"),
                    "実装済みの命令は #{FaRuby::OpcodeTable.codes.size} 個です"
  end

  def test_the_roadmap_method_count_matches
    assert_includes doc("doc/roadmap.md"), "組み込みメソッド #{BUILTIN_METHODS.size} 個"
  end

  # === 配置の数 ===

  # 容量は利用者が最初にぶつかる制限。README とずれると問い合わせになる
  def test_the_readme_states_the_pool_size
    assert_includes doc("README.md"), "#{Layout.default.max_arrays} 個で止まります"
  end
end
