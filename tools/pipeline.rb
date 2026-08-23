# frozen_string_literal: true

# パイプラインツール
# Ruby ソース → mrbc → パース → 逆アセンブル → コード生成 → シミュレーション
# の一括処理を行います。

require_relative "mrb_parser"
require_relative "disasm"
require_relative "vm_constants"
require_relative "memory_layout"
require_relative "plc_codegen"
require_relative "../simulator/kv_vm_simulator"

module FaRuby
  class Pipeline
    # mrbc のパスを検索
    MRBC_CANDIDATES = [
      File.join(__dir__, "..", "mruby", "build", "host", "bin", "mrbc"),
      File.join(__dir__, "..", "mruby", "build", "host", "bin", "mrbc.exe"),
      "mrbc",
      "mrbc.exe",
    ].freeze

    def initialize(source_path, mrbc_path: nil)
      @source_path = source_path
      @mrbc_path = mrbc_path || find_mrbc
    end

    def run
      puts "=== faRuby Pipeline ==="
      puts "Source: #{@source_path}"
      puts

      # 1. mrbc でコンパイル
      mrb_path = compile
      return unless mrb_path

      # 2. パース
      data = File.binread(mrb_path)
      parser = MrbParser.new(data).parse

      puts "=== RITE Header ==="
      puts parser.header
      puts
      puts "=== IREP ==="
      puts parser.irep
      puts

      # 3. 逆アセンブル
      puts "=== Disassembly ==="
      disasm = Disassembler.new(parser.irep)
      puts disasm.disassemble_to_s
      puts

      # 4. KV スクリプト生成
      codegen = PlcCodegen.new(parser.irep)
      kv_script = codegen.generate
      kv_path = @source_path.sub(/\.rb$/, "_load.kvs")
      File.write(kv_path, kv_script)
      puts "=== KV Script written to: #{kv_path} ==="
      puts

      # 5. シミュレータ実行
      puts "=== Simulator ==="
      sim = KvVmSimulator.new
      steps = sim.load_irep_and_run(parser.irep)
      puts "Executed #{steps} instructions"
      puts
      sim.dump_status
      puts
      sim.dump_registers

      # 一時ファイル削除
      File.delete(mrb_path) if File.exist?(mrb_path)

      sim
    end

    private

    def compile
      mrb_path = @source_path.sub(/\.rb$/, ".mrb")

      puts "Compiling with: #{@mrbc_path}"
      result = system(@mrbc_path, "-o", mrb_path, @source_path)

      unless result
        puts "ERROR: mrbc compilation failed"
        puts "  Make sure mrbc is installed and accessible."
        puts "  You can specify the path: Pipeline.new(source, mrbc_path: '/path/to/mrbc')"
        return nil
      end

      puts "Compiled: #{mrb_path}"
      mrb_path
    end

    def find_mrbc
      MRBC_CANDIDATES.each do |candidate|
        path = File.expand_path(candidate)
        return path if File.exist?(path)

        # PATH 上にあるか確認
        if system("which #{candidate} > /dev/null 2>&1") || system("where #{candidate} > NUL 2>&1")
          return candidate
        end
      end

      "mrbc"  # フォールバック
    end
  end
end

# コマンドラインから実行した場合
if __FILE__ == $0
  if ARGV.empty?
    puts "Usage: ruby pipeline.rb <source.rb> [--mrbc PATH]"
    exit 1
  end

  source = ARGV[0]
  mrbc = nil

  if ARGV.include?("--mrbc") && (idx = ARGV.index("--mrbc"))
    mrbc = ARGV[idx + 1]
  end

  pipeline = FaRuby::Pipeline.new(source, mrbc_path: mrbc)
  pipeline.run
end
