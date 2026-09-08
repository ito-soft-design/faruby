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

desc "Regenerate the VM scripts for every model from tools/opcode_table.rb"
task :vm_core do
  require_relative "tools/kvs_generator"
  require_relative "tools/config"
  require "fileutils"

  # faruby.yml の上書きを反映する。上書きした場合、生成物はその設備専用に
  # なるため、コミット済みのスクリプトとは一致しなくなる (テストが検出する)。
  #
  # **全機種ぶんまとめて出します。** 片方だけ生成すると、もう片方が
  # 古いまま残っていることに気づけないためです。
  config = FaRuby::Config.new
  stale = []
  FaRuby::Dialect.all.each do |dialect|
    layout = config.for_model(dialect.model).layout
    puts "#{dialect.model} (#{dialect.name}): #{layout}"
    generator = FaRuby::KvsGenerator.new(layout: layout, dialect: dialect)
    FileUtils.mkdir_p(generator.output_dir)
    changed = generator.write!
    if changed.empty?
      puts "  変更なし (生成結果は既存ファイルと同一)"
    else
      changed.each { |name| puts "  生成: plc/keyence/#{dialect.directory}/#{name}" }
      stale << dialect
    end
  end

  unless stale.empty?
    puts ""
    puts "KV Studio に取り込んで PLC に転送してください: #{stale.map(&:model).join(', ')}"
  end
end

desc "Alias for vm_core"
task vm: :vm_core

desc "Run test/ruby_programs on the PLC and check them against their headers"
task :hw do
  require_relative "tools/hardware_check"
  require_relative "tools/config"

  config = FaRuby::Config.new(connection: ENV["CONNECTION"]).validate_connection!
  puts "対象: #{[config.connection, config.model].compact.join(' / ')} @ #{config.plc_host}"
  puts "配置: #{config.layout}"
  puts ""

  results =
    begin
      FaRuby::HardwareCheck.new(config).run(only: ENV["ONLY"])
    rescue FaRuby::UnreachableError => e
      puts e.message
      exit 1
    end

  results.reject(&:skipped?).each do |r|
    puts format("  %-4s %-28s %s", r.ok? ? "OK" : "NG", r.name, r.detail)
    r.mismatches.each { |m| puts "         #{m}" }
  end

  skipped = results.select(&:skipped?)
  failed = results.reject { |r| r.ok? || r.skipped? }
  puts ""
  puts "確認した値: #{results.sum(&:checked)}"
  # **飛ばしたものは黙って落とさない。**確かめたつもりで抜けるのを防ぐ
  skipped.each { |r| puts "  飛ばし: #{r.name} (#{r.detail})" }

  puts ""
  if failed.empty?
    puts "すべて一致しました。"
  else
    puts "合わなかったもの:"
    failed.each { |r| puts "  #{r.name}  #{r.detail}" }
    exit 1
  end
end

desc "Compare the scripts in KV Studio with the generated ones"
task :transfer do
  require_relative "tools/transfer_check"
  require_relative "tools/config"

  # 照合するのはいまの接続先の機種。取り込むのは機種ごとに別だから
  config = FaRuby::Config.new(connection: ENV["CONNECTION"])
  dialect = FaRuby::Dialect.for(config.model)
  generator = FaRuby::KvsGenerator.new(layout: config.layout, dialect: dialect)

  path = ENV["MNM"] || FaRuby::TransferCheck.find_mnemonic(generator.output_dir)
  unless path
    puts "ニーモニックが見つかりません。"
    puts "KV Studio で書き出してから実行してください " \
         "(既定の場所: plc/keyence/#{dialect.directory}/**/tmp/*.mnm)"
    exit 1
  end

  puts "対象: #{[config.connection, config.model].compact.join(' / ')} (#{dialect.name})"
  puts "照合: #{path}"
  puts ""
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
    stale.each { |r| puts "  plc/keyence/#{dialect.directory}/#{r.name}" }
    exit 1
  end
end

task default: :test
