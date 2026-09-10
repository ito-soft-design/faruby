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

  # 生成器の代わり。**中身を返すだけです**
  #
  # `Minitest::Mock` は minitest の版によって読み込めないことがあり、
  # ここで見たいのは呼ばれ方ではなく突き合わせの結果なので、素の Ruby で
  # 足ります。
  Generator = Struct.new(:generate)

  def check_with(scripts, generated)
    generator = Generator.new(generated)
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

  # === KV-X500 (ST) の書き出し ===
  #
  # 体裁も文字コードも KV-5000 と違う。**名前だけで引き当てる。**
  #
  #   KV-5000  Shift_JIS  ;<h1/>vm_01_init
  #   KV-X500  UTF-16LE   ;vm_01_init  の次に AREA_ST が 1 行
  def st_mnemonic(scripts)
    body = scripts.flat_map do |name, source|
      [";#{name}", "AREA_ST"] + source.split("\n").map { |l| ";#{l}" } +
        ["LD CR2002", "MOV #0 EM0:Z9"]
    end
    (["DEVICE:62", ";MODULE:faruby"] + body).join("\r\n")
  end

  def check_st(scripts, generated)
    generator = Generator.new(generated)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "faruby.mnm")
      File.binwrite(path, "\xFF\xFE".b + st_mnemonic(scripts).encode("UTF-16LE").b)
      FaRuby::TransferCheck.new(path, generator: generator).results
    end
  end

  def test_the_st_export_is_read_through_its_bom_and_heading
    source = "// 見出し\nEM0:Z9 := 0;\n"
    results = check_st({ "vm_01_init" => source }, { "vm_01_init.st" => source })

    assert_equal [:same], results.map(&:state)
    assert_equal "vm_01_init.st", results.first.name
  end

  # 別の群の中身を取り込んでしまった場合 (実機で 1 度やりました)
  def test_the_wrong_script_in_a_slot_is_reported_as_differing
    want = "// オペコード 0x1F - 0x28\nEM0:Z9 := 0;\n"
    got  = "// オペコード 0x10 - 0x1E\nEM0:Z9 := 1;\n"
    results = check_st({ "vm_08_group4" => got }, { "vm_08_group4.st" => want })

    assert_equal [:differs], results.map(&:state)
    assert results.first.stale?
  end

  # 生成物の並び (ラダーに置く順) で返す
  def test_results_follow_the_ladder_order
    source = "EM0:Z9 = 0\n"
    generated = { "vm_01_init.kvs" => source, "vm_02_prologue.kvs" => source }
    results = check_with({ "vm_02_prologue" => source, "vm_01_init" => source }, generated)

    assert_equal ["vm_01_init.kvs", "vm_02_prologue.kvs"], results.map(&:name)
  end
end
