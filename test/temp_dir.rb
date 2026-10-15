# frozen_string_literal: true

module FaRuby
  # テストが書き出す一時ファイルの置き場
  #
  # **プロジェクトの中に置きます。** `C:/tmp` のような場所は環境によって
  # 違い、無いこともあります。他の作業と混ざるのも避けたいところです。
  #
  # **使う前に作ります。** git は空のディレクトリを持てないので、clone した
  # 直後には `tmp/` がありません。無いままだとテストがそこで落ちます。
  module TempDir
    module_function

    def path
      dir = File.expand_path("../tmp", __dir__)
      Dir.mkdir(dir) unless Dir.exist?(dir)
      dir
    end
  end
end
