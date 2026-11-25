require "rake/testtask"

# =========================================================================
# テスト
# =========================================================================
#
# **PLC と i8080 で分けます。** 要るものが違うためです。PLC 側は mrbc だけで
# 動きますが、i8080 側は r8080 エミュレータ (隣のリポジトリか R8080_PATH) と
# asm80 でアセンブルした vm_main.hex が要ります。
#
#   rake test         両方
#   rake test:plc     キーエンス・三菱と、共通のところ
#   rake test:i8080   i8080 バックエンド
#
# **分け方はファイル名です。** `test/test_i8080_*.rb` が i8080 側で、残りが
# PLC 側。どちらにも入らないファイルができないよう test_rake_tasks.rb が
# 見ています。
I8080_TESTS = FileList["test/test_i8080_*.rb"]
PLC_TESTS   = FileList["test/test_*.rb"].exclude(/test_i8080_/)

def test_libs(task)
  task.libs << "tools"
  task.libs << "simulator"
  task.libs << "test"
end

namespace :test do
  # **見出しは Rake::TestTask が付けます** ("Run tests for plc")。ここで
  # desc を書いても上書きされるので、代わりに後ろで足しています
  Rake::TestTask.new(:plc) do |t|
    test_libs(t)
    t.test_files = PLC_TESTS
  end

  Rake::TestTask.new(:i8080) do |t|
    test_libs(t)
    t.test_files = I8080_TESTS
  end
end

Rake::Task["test:plc"].add_description("Keyence and MELSEC, plus everything shared")
Rake::Task["test:i8080"].add_description("Needs r8080 (R8080_PATH) and vm_main.hex")

desc "Run every test (PLC and i8080)"
task test: %w[test:plc test:i8080]

desc "Start faRuby console (CONNECTION=name で接続先を選べる)"
task :console do
  # **CONNECTION は他のタスクと同じに揃えます。** 渡さないと黙って
  # connections.current の相手に繋ぎ、別の PLC を狙ったつもりで
  # 気づけません (`rake console CONNECTION=iQ_R` で実際にやりました)
  name = ENV["CONNECTION"]
  option = name ? " --connection #{name}" : ""
  system("cmd /c chcp 65001 >nul && ruby tools/console.rb#{option}")
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
    model = config.for_model(dialect.model)
    layout = model.layout
    # **容量が足りない機種は機能を外します** (tools/features.rb)。外した
    # 機能のコードは生成物から丸ごと落ちます
    features = model.features
    puts "#{dialect.model} (#{dialect.name}): #{layout}"
    puts "  機能: #{features}" unless features.all?
    generator = FaRuby::KvsGenerator.new(layout: layout, dialect: dialect,
                                         features: features)
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

  # **asm80 は新しいものを入れてください** (`npm install -g asm80@latest`)。
  #
  # `npm install -g asm80` だと **0.9.3 が入ります** — 新しい版の
  # `engines` が `npm: '1'` を要求していて、今の npm が外れるため、
  # npm が条件に合う古い版を選びます。0.9.3 は `bin` を持たないので
  # コマンドができず、`.include` も扱えません (doc/nd8080-guide.md)。
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

  bank_init_hex = File.expand_path("plc/i8080/r8080/bank_init.hex", __dir__)

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
    require_relative "tools/nd8080_hid"

    # mrbc でコンパイル
    mrb = Tempfile.new(["faruby", ".mrb"])
    mrb.close
    sh "mrbc -o #{mrb.path} #{src}"

    # 結合 HEX を生成
    mrb_data = File.binread(mrb.path)
    hex_gen = FaRuby::I8080BytecodeHex.new(mrb_data)
    hex_text = hex_gen.generate_hex(vm_hex_path: vm_hex)

    # Intel HEX → メモリイメージ → BTK データ群
    mem = FaRuby::IntelHex.parse(hex_text)
    btks = FaRuby::IntelHex.to_nd8080_btks(mem)

    btks.each_with_index do |(s, e, _), i|
      puts format("領域 %d: %04X-%04X (%d バイト)", i, s, e, e - s + 1)
    end

    # ND8080 に接続
    r = ND8080::Remote.new
    r.on_text = nil
    r.connect
    puts "ND8080 に接続しました"

    # --- バンク状態チェック ---
    # 0x0000 に書き込んで読み戻し、成功したら RAM モード
    original = r.save(0x0000, 0x0000)
    original_byte = original.getbyte(4)
    test_byte = (original_byte == 0xAA) ? 0x55 : 0xAA
    poke_btk = [0x0000, 0x0000].pack("nn") + [test_byte].pack("C")
    r.load(poke_btk)
    readback = r.save(0x0000, 0x0000)
    readback_byte = readback.getbyte(4)

    if readback_byte == test_byte
      # 書き込み成功 → RAM モード (拡張 RAM 選択済み)
      restore_btk = [0x0000, 0x0000].pack("nn") + [original_byte].pack("C")
      r.load(restore_btk)
      puts "RAM モード (拡張 RAM 選択済み)"
    else
      # 書き込み失敗 → ROM モード → 初期化プログラムを実行
      puts "ROM モード → 初期化プログラムを実行します..."
      bank_hex_text = File.read(bank_init_hex)
      bank_mem = FaRuby::IntelHex.parse(bank_hex_text)
      bank_btks = FaRuby::IntelHex.to_nd8080_btks(bank_mem)
      bank_btks.each { |_, _, btk_data| r.load(btk_data) }
      r.run(0x8400)
      r.wait_ready(10)
      puts "初期化完了 (ROM → 拡張 RAM クローン済み)"
    end

    # --- VM hex を書き込み ---
    btks.each_with_index do |(s, e, btk_data), i|
      puts format("書き込み中 (領域 %d: %04X-%04X)...", i, s, e)
      r.load(btk_data)
      back = r.save(s, e)
      if back == btk_data
        puts "  照合OK"
      else
        diff = (4...btk_data.bytesize).find { |j| back.getbyte(j) != btk_data.getbyte(j) }
        abort format("  照合NG: %04X 番地 書込=%02X 読出=%02X",
                      s + diff - 4, btk_data.getbyte(diff), back.getbyte(diff))
      end
    end

    r.close
    puts ""
    puts "書き込み完了。実行するには:"
    puts "  ruby #{nd8080_rb} run 8400"
  ensure
    mrb&.unlink
  end

  desc "Run program on ND8080 hardware"
  task :nd8080_run do
    addr = ENV["ADDR"] || "8400"
    sh "ruby #{nd8080_rb} run #{addr}"
  end
end

task default: :test
