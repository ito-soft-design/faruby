require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "tools"
  t.libs << "simulator"
  t.libs << "test"
  t.test_files = FileList["test/test_*.rb"]
end

desc "Start faRuby console"
task :console do
  system("cmd /c chcp 65001 >nul && ruby tools/console.rb")
end

desc "Regenerate plc/keyence/vm_*.kvs from tools/opcode_table.rb"
task :vm_core do
  require_relative "tools/kvs_generator"
  require_relative "tools/config"

  # faruby.yml の上書きを反映する。上書きした場合、生成物はその設備専用に
  # なるため、コミット済みのスクリプトとは一致しなくなる (テストが検出する)。
  config = FaRuby::Config.new
  layout = config.layout
  puts "配置: #{layout}"
  changed = FaRuby::KvsGenerator.new(layout: layout).write!
  if changed.empty?
    puts "変更なし (生成結果は既存ファイルと同一)"
  else
    changed.each { |name| puts "生成: plc/keyence/#{name}" }
    puts ""
    puts "KV Studio に取り込んで PLC に転送してください。"
  end
end

desc "Regenerate plc/keyence/x500/vm_*.st (KV-X500 の ST) from tools/opcode_table.rb"
task :vm_st do
  require_relative "tools/kvs_generator"
  require_relative "tools/config"

  dir = File.expand_path("plc/keyence/x500", __dir__)
  require "fileutils"
  FileUtils.mkdir_p(dir)

  layout = FaRuby::Config.new.layout
  puts "配置: #{layout}"
  generator = FaRuby::KvsGenerator.new(layout: layout, dialect: FaRuby::StDialect.new)
  changed = generator.write!(dir)
  if changed.empty?
    puts "変更なし (生成結果は既存ファイルと同一)"
  else
    changed.each { |name| puts "生成: plc/keyence/x500/#{name}" }
    puts ""
    puts "**未確認です。** KV-X500 で変換が通るかを確かめてください。"
  end
end

desc "Compare the scripts in KV Studio with the generated ones"
task :transfer do
  require_relative "tools/transfer_check"
  require_relative "tools/config"

  path = ENV["MNM"] || FaRuby::TransferCheck.find_mnemonic
  unless path
    puts "ニーモニックが見つかりません。"
    puts "KV Studio で書き出してから実行してください (既定の場所: plc/keyence/*/tmp/*.mnm)"
    exit 1
  end

  puts "照合: #{path}"
  puts ""
  layout = FaRuby::Config.new.layout
  generator = FaRuby::KvsGenerator.new(layout: layout)
  results = FaRuby::TransferCheck.new(path, generator: generator).results
  results.each do |r|
    mark = r.state == :same ? "一致" : "違い"
    puts format("  %-22s %s  %s", r.name, mark, r.detail)
  end

  stale = results.select(&:stale?)
  puts ""
  if stale.empty?
    puts "すべて一致しています。"
  else
    puts "KV Studio に取り込み直してください:"
    stale.each { |r| puts "  plc/keyence/#{r.name}" }
    exit 1
  end
end

task default: :test
