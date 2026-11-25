# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/config"

# PLC に触る rake タスクの接続先の渡し方
#
# **渡し忘れると黙って別の PLC に繋ぎます。** `rake console` が
# `CONNECTION` を見ていなかったため、iQ-R を狙ったつもりで
# `connections.current` の相手に繋いでいました。繋がらない相手だと
# 気づけますが、繋がる相手だと気づけません。
class TestRakeTasks < Minitest::Test
  RAKEFILE = File.read(File.join(FaRuby::Config::PROJECT_ROOT, "Rakefile"), encoding: "utf-8")

  # PLC に触るタスク。どれも接続先を選べなければならない
  PLC_TASKS = %w[console hw bench transfer].freeze

  # タスク 1 つ分の本体 (`task :name do` から次の `task` / `desc` まで)
  def body(name)
    RAKEFILE[/^task :#{name} do$.*?(?=^(?:desc|task)\b)/m] ||
      RAKEFILE[/^task :#{name} do$.*\z/m]
  end

  def test_plc_に触るタスクはすべて_CONNECTION_を見る
    PLC_TASKS.each do |name|
      source = body(name)

      refute_nil source, "#{name} タスクが見つかりません"
      assert_includes source, 'ENV["CONNECTION"]',
                      "rake #{name} が CONNECTION を見ていません " \
                      "(渡し忘れると connections.current の相手に繋ぎます)"
    end
  end

  # 見出しにも書いておく。`rake -T` で分かるように
  def test_console_の見出しに_CONNECTION_が出る
    desc = RAKEFILE[/^desc "(.*)"\ntask :console do$/, 1]

    assert_includes desc.to_s, "CONNECTION"
  end

  # **CONNECTION を渡さないときは --connection を付けない。**
  # 空文字を渡すと OptionParser が引数不足で落ちます
  def test_CONNECTION_が無いときは_オプションを付けない
    source = body("console")

    assert_match(/ENV\["CONNECTION"\].*\?.*--connection/m, source,
                 "CONNECTION の有無で分けていません")
  end

  # === テストの分け方 ===
  #
  # **PLC と i8080 は要るものが違います。** i8080 は r8080 エミュレータと
  # vm_main.hex が要るので、PLC だけを触る環境では飛びます。分け方は
  # ファイル名 (`test/test_i8080_*.rb`) です。

  def test_rake_test_は_plc_と_i8080_の両方を走らせる
    assert_match(/^task test: .*test:plc.*test:i8080/, RAKEFILE,
                 "rake test がどちらか片方しか走らせていません")
  end

  # **どちらにも入らないファイルを作れないこと。** 名前で分けているので、
  # i8080 を触るのに別の名前を付けると PLC 側に混ざり、r8080 が無い環境で
  # 落ちます (飛ばされるのではなく落ちます)
  def test_i8080_を触るテストは_test_i8080_で始まる
    strays = Dir[File.join(FaRuby::Config::PROJECT_ROOT, "test", "test_*.rb")].reject do |path|
      File.basename(path).start_with?("test_i8080_")
    end.select do |path|
      # **読み込んでいるものを見ます。** 名前が出てくるだけ (この検査自身の
      # ように) では引っかけません
      File.read(path, encoding: "utf-8").match?(/require_relative\s+["'][^"']*i8080_board/)
    end

    assert_empty strays.map { |p| File.basename(p) },
                 "i8080 を触るテストは test_i8080_ で始めてください " \
                 "(rake test:plc に混ざり、r8080 が無い環境で落ちます)"
  end
end
