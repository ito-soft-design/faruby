# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"

require_relative "temp_dir"
require_relative "../tools/console/commands"

# compile がソースを探す道筋
#
# **プログラムは programs/ に置くので、ファイル名だけで書けるようにします。**
# 毎回 `compile programs/blink.rb` と打つのは、置き場が 1 つしかない以上
# 冗長です。
class TestConsoleSourcePath < Minitest::Test
  # **接続もコンパイルもしません。** 探す道筋だけを見るので、
  # initialize が受け取るものは使われません
  def commands = FaRuby::Console::Commands.new(config: nil, adapter: nil, transfer: nil)

  def find(name) = commands.send(:find_source, name)

  def candidates(name) = commands.send(:source_candidates, name)

  # 作業フォルダを移して試す。**Dir.pwd を見るため**
  def in_workdir
    dir = File.join(FaRuby::TempDir.path, "source_path")
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(File.join(dir, "programs"))
    Dir.chdir(dir) { yield dir }
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_ファイル名だけで_programs_から見つかる
    in_workdir do |dir|
      path = File.join(dir, "programs", "blink.rb")
      File.write(path, "$DM100 = 1\n")

      assert_equal File.file?(path), true
      assert_equal path, find("blink.rb")
    end
  end

  # **そのままの指定を先に見ます。** パスで書いたならそれが意図です
  def test_書かれたパスが優先される
    in_workdir do |dir|
      File.write(File.join(dir, "here.rb"), "a = 1\n")
      File.write(File.join(dir, "programs", "here.rb"), "b = 2\n")

      assert_equal "here.rb", find("here.rb")
    end
  end

  def test_無ければ_nil_を返す
    in_workdir do
      assert_nil find("no_such.rb")
    end
  end

  # **リポジトリの programs/ も見ます。** 別の場所で作業していても、
  # 置き場に入れたものは名前だけで届きます
  def test_リポジトリの_programs_も探す
    root = FaRuby::Console::Commands::PROGRAM_DIR
    in_workdir do
      assert_includes candidates("blink.rb"),
                      File.join(FaRuby::Config::PROJECT_ROOT, root, "blink.rb")
    end
  end

  # 作業フォルダがリポジトリそのものなら、同じ場所を 2 度探さない
  def test_同じ場所を重ねて探さない
    Dir.chdir(FaRuby::Config::PROJECT_ROOT) do
      assert_equal candidates("blink.rb").uniq, candidates("blink.rb")
    end
  end
end
