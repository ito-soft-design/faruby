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

desc "Regenerate plc/keyence/vm_core.kvs from tools/opcode_table.rb"
task :vm_core do
  require_relative "tools/kvs_generator"
  require_relative "tools/config"

  # faruby.yml の上書きを反映する。上書きした場合、生成物はその設備専用に
  # なるため、コミット済みの vm_core.kvs とは一致しなくなる (テストが検出する)。
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

task default: :test
