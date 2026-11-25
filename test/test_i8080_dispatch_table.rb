# frozen_string_literal: true

require "minitest/autorun"
require "set"

require_relative "../tools/opcode_table"

# i8080 のディスパッチ表とオペコード表の突き合わせ
#
# **i8080 側の番号は手書きです。** PLC 側は `opcode_table.rb` から生成される
# ので番号が動けば追随しますが、`dispatch_table` は**並び順が番号そのもの**で、
# 名前はコメントにしか存在しません。1 つずれると全命令が隣の処理へ飛びます。
#
# `rake i8080:constants` は `OP_*` と `FMT_*` を `vm_constants.a80` に出し
# ますが、**アセンブリはどちらも参照していません** (grep で 0 件)。つまり
# opcode_table.rb と i8080 をつないでいるのはこの表のコメントだけなので、
# ここだけを見ます。
#
# **エミュレータは要りません。** ファイルを読むだけなので、r8080 が無くても
# 走ります。
class TestI8080DispatchTable < Minitest::Test
  ASM_DIR = File.expand_path("../plc/i8080/r8080", __dir__)
  VM_MAIN = File.join(ASM_DIR, "vm_main.a80")

  # 未実装の印。綴り間違いと区別が付くよう、飛び先の実在も別に見る
  UNIMPLEMENTED = "0000h"

  # `dw 飛び先   ; 番号 名前` の行
  #
  # 末尾に註釈が付くものがあるので (`; 19 OP_GETIV (= OP_GETGV)`)、
  # 行末までは縛りません。
  ENTRY = /\A\s*dw\s+(\S+)\s*;\s*([0-9A-Fa-f]{2})\s+(OP_\w+)/

  def table_body
    @table_body ||= begin
      text = File.read(VM_MAIN, encoding: "UTF-8")
      after = text.split(/^dispatch_table:\s*$/, 2)[1]
      refute_nil after, "dispatch_table: が見つかりません (#{VM_MAIN})"
      before = after.split(/^dispatch_table_end:/, 2)[0]
      refute_nil before, "dispatch_table_end: が見つかりません (#{VM_MAIN})"
      before
    end
  end

  # **`dw` の行は 1 つも読み飛ばしません。** 飛ばすと位置がずれて、
  # 番号の検査が意味を失います
  def dw_lines = table_body.lines.select { |l| l.match?(/\A\s*dw\s/) }

  def entries
    @entries ||= dw_lines.filter_map do |line|
      m = line.match(ENTRY) or next
      { target: m[1], code: m[2].to_i(16), name: m[3].to_sym }
    end
  end

  def hex(code) = format("%02X", code)

  def test_表が読めて_dw_の行が全部数えられる
    refute_empty entries, "dispatch_table を読めませんでした"
    assert_equal dw_lines.size, entries.size,
                 "番号と名前のコメントが無い dw の行があります:\n" +
                 dw_lines.reject { |l| l.match?(ENTRY) }.map { |l| "  #{l.strip}" }.join("\n")
  end

  # **並び順が番号です。** コメントの番号が位置とずれていたら、
  # そこから後ろが全部ずれている
  def test_どの行もコメントの番号の位置に居る
    entries.each_with_index do |e, i|
      assert_equal i, e[:code],
                   "#{i} 番目の dw のコメントが #{hex(e[:code])} になっています (#{e[:name]})"
    end
  end

  def test_名前が_opcode_table_と一致する
    entries.each do |e|
      expected = FaRuby::OpcodeTable::MRUBY_OPCODES[e[:code]]
      assert expected, "#{hex(e[:code])} は opcode_table.rb にありません (#{e[:name]})"
      assert_equal expected[0], e[:name],
                   "#{hex(e[:code])} は opcode_table.rb では #{expected[0]} です"
    end
  end

  # **飛び先の綴り間違いは 0000h と区別が付きません。** どちらも
  # アセンブラは通し、実行して初めて分かる
  def test_飛び先のラベルが実在する
    labels = Dir[File.join(ASM_DIR, "*.a80")].flat_map { |f|
      File.read(f, encoding: "UTF-8").scan(/^([a-z_][a-z0-9_]*):/).flatten
    }.to_set

    entries.reject { |e| e[:target] == UNIMPLEMENTED }.each do |e|
      assert_includes labels, e[:target], "#{e[:name]} の飛び先 #{e[:target]} がありません"
    end
  end

  # 0 から始まり、opcode_table.rb にある番号で終わること
  def test_表の範囲が_0_から始まりオペコード表に収まる
    assert_equal 0, entries.first[:code], "表が 00 から始まっていません"
    max = FaRuby::OpcodeTable::MRUBY_OPCODES.keys.max
    assert_operator entries.last[:code], :<=, max,
                    "opcode_table.rb に無い番号まで表があります"
  end

  # **実装したのに表へ繋いでいない**ハンドラが無いこと
  #
  # `do_op_*` を書いても `dw` を 0000h のままにすると、その命令は
  # 未知のオペコードで止まります。足し忘れはここで出ます
  def test_実装したハンドラが表から呼ばれている
    handlers = Dir[File.join(ASM_DIR, "*.a80")].flat_map { |f|
      File.read(f, encoding: "UTF-8").scan(/^(do_op_[a-z0-9_]*):/).flatten
    }.to_set
    wired = entries.map { |e| e[:target] }.to_set

    # 枝のための補助ラベル (別のハンドラから jmp されるもの) は除く
    orphans = (handlers - wired).reject do |label|
      Dir[File.join(ASM_DIR, "*.a80")].any? do |f|
        File.read(f, encoding: "UTF-8").match?(/\b(?:jmp|jz|jnz|jc|jnc|call)\s+#{label}\b/)
      end
    end

    assert_empty orphans,
                 "表から呼ばれていない do_op_* があります: #{orphans.to_a.sort.join(', ')}"
  end
end
