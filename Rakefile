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
      changed.each { |name| puts "  生成: plc/#{dialect.directory}/#{name}" }
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

desc "Measure execution speed on the PLC"
task :bench do
  require_relative "tools/benchmark"
  require_relative "tools/config"

  config = FaRuby::Config.new(connection: ENV["CONNECTION"]).validate_connection!
  bench = FaRuby::Benchmark.new(config)
  seconds = (ENV["SECONDS"] || FaRuby::Benchmark::DEFAULT_SECONDS).to_f
  rounds = (ENV["ROUNDS"] || FaRuby::Benchmark::DEFAULT_ROUNDS).to_i

  puts "対象: #{[config.connection, config.model].compact.join(' / ')} @ #{config.plc_host}"
  puts "1スキャンあたりの命令数: #{config.steps_per_cycle}"
  puts "#{seconds} 秒 × #{rounds} 回"
  puts ""

  results =
    begin
      bench.run(seconds: seconds, rounds: rounds, only: ENV["ONLY"])
    rescue FaRuby::UnreachableError => e
      puts e.message
      exit 1
    end

  puts format("  %-10s %12s %10s %14s %10s", "ループ", "命令/秒", "1命令", "スキャン周期", "ばらつき")
  results.each do |r|
    puts format("  %-10s %12s %8.1f µs %11.2f ms %8.1f%%",
                r.name, r.rate.round.to_s.gsub(/(\d)(?=(\d{3})+\z)/, '\1,'),
                r.micros_per_step, r.scan_ms, r.spread)
  end

  # **1 周の命令数が前提どおりか。**ずれたら前に測った数字と並べられない
  drifted = results.reject(&:steps_match?)
  unless drifted.empty?
    puts ""
    puts "1 周の命令数が変わっています。tools/benchmark.rb の steps_per_loop を"
    puts "直すまで、前に測った数字と並べないでください:"
    drifted.each do |r|
      puts format("  %-10s 前提 %d 命令/周  実測 %.3f", r.name, r.expected_steps_per_loop,
                  r.steps_per_loop)
    end
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
         "(既定の場所: plc/#{dialect.directory}/**/tmp/*.mnm)"
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
    stale.each { |r| puts "  plc/#{dialect.directory}/#{r.name}" }
    exit 1
  end
end

# =========================================================================
# i8080 バックエンド
# =========================================================================
#
# PLC 向けの rake vm_core とは独立した名前空間。
# asm80 と r8080 エミュレータが必要です。
#
#   rake i8080:constants   定数ヘッダ (vm_constants.a80) を再生成
#   rake i8080:asm         VM をアセンブル (vm_main.hex)
#   rake i8080:build       constants + asm をまとめて実行
#   rake i8080:run         Ruby ソースをコンパイル → r8080 で実行
#
#   例: rake i8080:run SRC=test/ruby_programs/addition.rb
#        rake i8080:run SRC=/tmp/test.rb

namespace :i8080 do
  asm_dir  = "plc/i8080/r8080"
  vm_hex   = "#{asm_dir}/vm_main.hex"
  vm_main  = "#{asm_dir}/vm_main.a80"

  desc "Regenerate vm_constants.a80 from Ruby definitions"
  task :constants do
    require_relative "tools/i8080_constants_gen"
    path = File.join(asm_dir, "vm_constants.a80")
    content = FaRuby::I8080ConstantsGen.generate
    if File.exist?(path) && File.read(path) == content
      puts "vm_constants.a80: 変更なし"
    else
      File.write(path, content)
      puts "vm_constants.a80: 生成しました"
    end
  end

  desc "Assemble the i8080 VM (vm_main.a80 → vm_main.hex)"
  task :asm do
    sh "asm80 -m I8080 #{vm_main}"
    puts "アセンブル完了: #{vm_hex}"
  end

  desc "Build the i8080 VM (constants + assemble)"
  task build: %i[constants asm]

  desc "Compile Ruby source and run on r8080 emulator"
  task :run do
    src = ENV["SRC"]
    unless src
      warn "SRC を指定してください: rake i8080:run SRC=path/to/program.rb"
      exit 1
    end

    require "tempfile"
    require_relative "tools/i8080_bytecode_hex"

    # mrbc でコンパイル
    mrb = Tempfile.new(["faruby", ".mrb"])
    mrb.close
    sh "mrbc -o #{mrb.path} #{src}"

    # 結合 HEX を生成
    mrb_data = File.binread(mrb.path)
    hex_gen = FaRuby::I8080BytecodeHex.new(mrb_data)
    combined = Tempfile.new(["combined", ".hex"])
    combined.write(hex_gen.generate_hex(vm_hex_path: vm_hex))
    combined.close

    # r8080 で実行
    require_relative "tools/i8080_board"
    board = FaRuby::I8080Board.new
    board.load_hex(combined.path)
    result = board.run
    puts "Result: #{result}"
    puts board.dump_state
  ensure
    mrb&.unlink
    combined&.unlink
  end

  nd8080_rb = File.expand_path("tools/nd8080.rb", __dir__)

  desc "Generate combined HEX for ND8080"
  task :hex do
    src = ENV["SRC"]
    unless src
      warn "SRC を指定してください: rake i8080:hex SRC=path/to/program.rb"
      exit 1
    end

    require "tempfile"
    require_relative "tools/i8080_bytecode_hex"

    mrb = Tempfile.new(["faruby", ".mrb"])
    mrb.close
    sh "mrbc -o #{mrb.path} #{src}"

    mrb_data = File.binread(mrb.path)
    hex_gen = FaRuby::I8080BytecodeHex.new(mrb_data)
    hex_text = hex_gen.generate_hex(vm_hex_path: vm_hex)

    out = ENV["OUT"] || "combined.hex"
    File.write(out, hex_text)
    puts "生成: #{out}"
  ensure
    mrb&.unlink
  end

  desc "Upload combined HEX to ND8080 via USB"
  task :upload do
    src = ENV["SRC"]
    unless src
      warn "SRC を指定してください: rake i8080:upload SRC=path/to/program.rb"
      exit 1
    end
    require "tempfile"
    require_relative "tools/i8080_bytecode_hex"
    require_relative "tools/intel_hex"

    # mrbc でコンパイル
    mrb = Tempfile.new(["faruby", ".mrb"])
    mrb.close
    sh "mrbc -o #{mrb.path} #{src}"

    # 結合 HEX を生成
    mrb_data = File.binread(mrb.path)
    hex_gen = FaRuby::I8080BytecodeHex.new(mrb_data)
    hex_text = hex_gen.generate_hex(vm_hex_path: vm_hex)

    # Intel HEX → メモリイメージ → BTK ファイル群
    mem = FaRuby::IntelHex.parse(hex_text)
    btks = FaRuby::IntelHex.to_nd8080_btks(mem)

    btk_files = []
    btks.each_with_index do |(s, e, btk_data), i|
      f = Tempfile.new(["nd8080_#{i}", ".btk"])
      f.binmode
      f.write(btk_data)
      f.close
      btk_files << f
      puts format("領域 %d: %04X-%04X (%d バイト)", i, s, e, e - s + 1)
    end

    # nd8080.rb で書き込み
    btk_files.each_with_index do |f, i|
      puts "書き込み中 (領域 #{i})..."
      sh "ruby #{nd8080_rb} load #{f.path} --verify"
    end

    puts ""
    puts "書き込み完了。実行するには:"
    puts "  ruby #{nd8080_rb} run 8400"
  ensure
    mrb&.unlink
    btk_files&.each(&:unlink)
  end

  desc "Run program on ND8080 hardware"
  task :nd8080_run do
    addr = ENV["ADDR"] || "8400"
    sh "ruby #{nd8080_rb} run #{addr}"
  end
end

task default: :test
