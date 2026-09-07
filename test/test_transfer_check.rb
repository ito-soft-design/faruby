# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require_relative "../tools/transfer_check"

# 取り込み済みスクリプトとの突き合わせ
#
# **どのファイルを取り込み直すかを PLC 側の中身から決める**ための道具です。
# コミットの差分では、取り込み忘れや前回どこまで取り込んだかが分かりません。
class TestTransferCheck < Minitest::Test
  # ニーモニックの体裁を真似る
  #
  #   ;<h1/>名前        スクリプトの始まり
  #   ;元のソース行     直後にそのまま並ぶ
  #   LD CR2002         変換後のラダー命令 (';' が付かない)
  #
  # ソースはこの後にもう一度ラダー命令と交互に現れる。そこまで読むと
  # 行がずれるので、生成物の行数だけ取る作りになっている。
  def mnemonic(scripts)
    body = scripts.flat_map do |name, source|
      [";<h1/>#{name}"] + source.split("\n").map { |l| ";#{l}" } +
        ["LD CR2002", "MOV #0 EM0:Z9"] +
        source.split("\n").flat_map { |l| [";#{l}", "LD CR2002"] }
    end
    (["DEVICE:52"] + body).join("\r\n")
  end

  def check_with(scripts, generated)
    generator = Minitest::Mock.new
    2.times { generator.expect(:generate, generated) }
    Dir.mktmpdir do |dir|
      path = File.join(dir, "faruby_vm.mnm")
      File.binwrite(path, mnemonic(scripts).encode("windows-31j"))
      FaRuby::TransferCheck.new(path, generator: generator).results
    end
  end

  def test_matching_scripts_are_reported_as_same
    source = "' 見出し\nEM0:Z9 = 0\n"
    results = check_with({ "vm_01_init" => source }, { "vm_01_init.kvs" => source })

    assert_equal [:same], results.map(&:state)
    assert_equal "vm_01_init.kvs", results.first.name
    refute results.first.stale?
  end

  # 古いまま残っているものを見つけるのがこの道具の目的
  def test_a_script_left_behind_is_reported_with_the_first_differing_line
    old = "' 見出し\nEM0:Z9 = 0\n"
    new = "' 見出し\nEM0:Z9 = 1\n"
    results = check_with({ "vm_01_init" => old }, { "vm_01_init.kvs" => new })

    assert_equal [:differs], results.map(&:state)
    assert_includes results.first.detail, "2 行目"
    assert results.first.stale?
  end

  # 群を増やすと、まだ取り込んでいないスクリプトが出る
  def test_a_script_never_imported_is_reported_as_missing
    source = "EM0:Z9 = 0\n"
    results = check_with({ "vm_01_init" => source },
                         { "vm_01_init.kvs" => source, "vm_02_prologue.kvs" => source })

    assert_equal %i[same missing], results.map(&:state)
    assert_equal "vm_02_prologue.kvs", results.last.name
  end

  # 生成物の並び (ラダーに置く順) で返す
  def test_results_follow_the_ladder_order
    source = "EM0:Z9 = 0\n"
    generated = { "vm_01_init.kvs" => source, "vm_02_prologue.kvs" => source }
    results = check_with({ "vm_02_prologue" => source, "vm_01_init" => source }, generated)

    assert_equal ["vm_01_init.kvs", "vm_02_prologue.kvs"], results.map(&:name)
  end
end
