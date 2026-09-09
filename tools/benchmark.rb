# frozen_string_literal: true

# 実行速度の計測
#
# **終わらないループを走らせ、`STEP_COUNT` の伸びを見ます。** スキャン周期は
# 1 スキャンあたりの命令数 (`STEPS_PER_CYCLE`) を実行速度で割って出します。
#
# 使い方: `rake bench` (接続先は faruby.yml の connections.current)
#
# ## ループを変えないこと
#
# **測るループはここに固定してあります。** 変えると前に測った数字と並べられ
# なくなります。実際に 1 度それで足をすくわれました。`STEP_COUNT` が使えな
# かったころは「1 周 9 命令」を掛けて出しており、後から数えたら 4 命令でした。
# 昔の値と今の値は比べられません。
#
# そのため 1 周の命令数もここに書いておき、**測るたびに実測と突き合わせます。**
# mruby やコード生成が変わって命令数が動いたら、黙って別の数字になるのでは
# なく、その場で知らせます。
#
# ## 触るデバイス
#
# ループの周回数を 1 つのワードデバイスに置きます。**置き場はメーカーで違い
# ますが、測るループは同じ**です。ラダーが使っていないことを確かめてください。
#
#   キーエンス  `$DM660L` (DM660-DM661)
#   三菱        `$D3660L` (D3660-D3661)

require_relative "config"
require_relative "mrb_parser"
require_relative "plc_codegen"
require_relative "device_syntax"
require_relative "dialect"
require_relative "vm_constants"
require_relative "console/plc_connection"
require_relative "console/memory_transfer"

module FaRuby
  class Benchmark
    include VmConstants

    # 周回数を置くデバイス
    #
    # **置き場だけがメーカーで違います。** ループそのものは同じなので、
    # 機種をまたいで数字を並べられます。
    COUNTERS = { "keyence_kv" => %w[DM 660], "mitsubishi_mc" => %w[D 3660] }.freeze

    DEFAULT_SECONDS = 5.0
    DEFAULT_ROUNDS  = 3

    # 走り出しを待つ
    WARMUP = 0.5

    # source は周回数の置き場を受け取って組み立てます
    Loop = Struct.new(:name, :note, :steps_per_loop, :source, keyword_init: true)

    # **測るループ。変えないこと。**
    LOOPS = [
      Loop.new(
        name: "OP_ADDI",
        note: "従来の計測ループ",
        steps_per_loop: 4,   # OP_GETGV / OP_ADDI / OP_SETGV / OP_JMP
        source: ->(counter) { <<~RUBY }
          $#{counter}L = 0
          while true
            $#{counter}L = $#{counter}L + 1
          end
        RUBY
      ),
      Loop.new(
        name: "OP_ADD",
        note: "足し算を通す",
        steps_per_loop: 5,   # OP_GETGV / OP_MOVE / OP_ADD / OP_SETGV / OP_JMP
        source: ->(counter) { <<~RUBY }
          one = 1
          $#{counter}L = 0
          while true
            $#{counter}L = $#{counter}L + one
          end
        RUBY
      ),
    ].freeze

    Result = Struct.new(:name, :note, :rates, :steps_per_loop, :expected_steps_per_loop,
                        :steps_per_cycle) do
      # ばらつきがあるので速い方を採る。遅い側は他の負荷を拾っている
      def rate = rates.max.to_f

      def micros_per_step = 1_000_000 / rate

      def scan_ms = steps_per_cycle / rate * 1000

      def spread = (rates.max - rates.min) / rate * 100

      # 1 周の命令数が前提どおりか。ずれたら前の数字と並べられない
      def steps_match? = steps_per_loop.round == expected_steps_per_loop
    end

    def initialize(config, adapter: nil)
      @config = config
      @adapter = adapter || Console::PlcConnection.create(config)
      @layout = config.layout.for_instance(0)
      @transfer = Console::MemoryTransfer.new(@adapter, layout: @layout)
    end

    def reachable!
      @transfer.read_vm_state
      self
    rescue StandardError => e
      raise UnreachableError,
            "#{@config.plc_host}:#{@config.plc_port} に繋がりません (#{e.class}: #{e.message})"
    end

    def run(seconds: DEFAULT_SECONDS, rounds: DEFAULT_ROUNDS, only: nil)
      reachable!
      loops = only ? LOOPS.select { |l| l.name.include?(only) } : LOOPS
      loops.map { |target| measure(target, seconds.to_f, rounds.to_i) }
    end

    private

    def measure(target, seconds, rounds)
      load_program(target.source.call(counter_name))

      steps_total = 0
      loops_total = 0
      rates = rounds.times.map do
        before = sample
        sleep seconds
        after = sample
        steps_total += after[:steps] - before[:steps]
        loops_total += after[:loops] - before[:loops]
        (after[:steps] - before[:steps]) / (after[:time] - before[:time])
      end
      @transfer.write_status(VM_STOPPED)

      Result.new(target.name, target.note, rates,
                 loops_total.zero? ? 0.0 : steps_total.to_f / loops_total,
                 target.steps_per_loop, @config.steps_per_cycle)
    end

    # この機種の周回数の置き場
    def counter
      COUNTERS.fetch(@config.plc_protocol) do
        raise ArgumentError, "周回数の置き場が決まっていません (#{@config.plc_protocol})"
      end
    end

    def counter_device = counter[0]
    def counter_addr   = counter[1]
    def counter_name   = counter.join

    # 周回数と命令数を同じ時点で読む

    def sample
      { loops: @adapter.read_device_width(counter_device, counter_addr, ACCESS_L),
        steps: @transfer.read_vm_state[:step_count],
        time: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end

    def load_program(source)
      irep = compile(source)
      @transfer.write_status(VM_STOPPED)
      codegen = PlcCodegen.new(irep, steps_per_cycle: @config.steps_per_cycle, layout: @layout,
                               device_syntax: DeviceSyntax.for_dialect(Dialect.for(@config.model)))
      @transfer.write_image(codegen.memory_image)
      @transfer.write_fixed_image(codegen.fixed_image)
      @transfer.write_status(VM_RUNNING)
      sleep WARMUP
    end

    def compile(source)
      require "tempfile"
      file = Tempfile.new(["bench", ".rb"])
      file.write(source)
      file.close
      mrb = "#{file.path}.mrb"
      raise "mrbc が実行できません: #{@config.mrbc_path}" unless
        system(@config.mrbc_path, "-o", mrb, file.path, out: File::NULL, err: File::NULL)

      irep = MrbParser.new(File.binread(mrb)).parse.irep
      File.delete(mrb)
      file.unlink
      irep
    end
  end
end
