# frozen_string_literal: true

# 実機でのプログラム確認
#
# **test/ruby_programs を順に PLC で走らせ、見出しに書いた期待値と
# 突き合わせます。** シミュレータでは再現できない不具合が何度も出ているので、
# 機種を増やしたり VM を直したりしたら、ここを通してから完了にします。
#
# 使い方: `rake hw` (接続先は faruby.yml の connections.current)
#
# 見出しの書き方:
#
#   # 対象機種: KV-5000        省略するとどの機種でも走らせる
#   #
#   # 期待値:
#   #   $DM120 = 1       説明
#   #   $DM520F = 3.0    幅サフィックスも書ける
#
# 期待値の無いプログラムは飛ばします。値をデバイスに残さないため、
# 実機では確かめようがないからです。
#
# **デバイスでない名前 ($total などの汎用グローバル変数) は飛ばします。**
# ホストから読む手立てがありません。

require_relative "config"
require_relative "mrb_parser"
require_relative "plc_codegen"
require_relative "vm_constants"
require_relative "console/plc_connection"
require_relative "console/memory_transfer"

module FaRuby
  # PLC に届かない場合に発生
  class UnreachableError < StandardError; end

  class HardwareCheck
    include VmConstants

    PROGRAM_DIR = File.expand_path("../test/ruby_programs", __dir__)

    # プログラムが終わるのを待つ間隔と回数
    POLL_INTERVAL = 0.05
    POLL_LIMIT    = 200

    Result = Struct.new(:name, :state, :detail, :checked, :mismatches) do
      def ok? = state == :ok
      def skipped? = state == :skipped
    end

    # 見出しの「期待値:」から [デバイス, 値] を読む
    #
    # 見出しは `#` で始まる行が続く限りです。本文に入ったら終わりにします。
    def self.expectations(source)
      lines = source.lines
      start = lines.index { |line| line.include?("期待値:") }
      return [] unless start

      lines[(start + 1)..].take_while { |line| line.start_with?("#") }.filter_map do |line|
        m = line.match(/\A#\s+\$(\w+)\s*=\s*(-?\d+(?:\.\d+)?)/)
        next unless m

        [m[1], m[2].include?(".") ? m[2].to_f : m[2].to_i]
      end
    end

    # 見出しの「対象機種:」。書かなければどの機種でも走らせる
    def self.models(source)
      line = source.lines.find { |l| l.match?(/\A#\s*対象機種:/) }
      return nil unless line

      line.sub(/\A#\s*対象機種:/, "").split(/[,、\s]+/).reject(&:empty?)
    end

    def initialize(config, adapter: nil, dir: PROGRAM_DIR)
      @config = config
      @adapter = adapter || Console::PlcConnection.create(config)
      @layout = config.layout.for_instance(0)
      @transfer = Console::MemoryTransfer.new(@adapter, layout: @layout)
      @dir = dir
    end

    def programs(only = nil)
      paths = Dir[File.join(@dir, "*.rb")].sort
      only ? paths.select { |path| File.basename(path).include?(only) } : paths
    end

    # 走らせる前に 1 度読んでおく
    #
    # **届かないときに読み書きの途中で落ちると、何が悪いのか分かりません。**
    # plc_access は繋がらないまま進んで nil で転びます。ここで止めます。
    def reachable!
      @transfer.read_vm_state
      self
    rescue StandardError => e
      raise UnreachableError,
            "#{@config.plc_host}:#{@config.plc_port} に繋がりません (#{e.class}: #{e.message})"
    end

    # [Result] を返す。並びはファイル名順
    def run(only: nil)
      reachable!
      programs(only).map { |path| check(path) }
    end

    private

    def check(path)
      name = File.basename(path)
      source = File.read(path, encoding: "utf-8")

      models = self.class.models(source)
      if models && !models.include?(@config.model)
        return Result.new(name, :skipped, "#{models.join(' / ')} 専用", 0, [])
      end

      wanted = self.class.expectations(source)
      return Result.new(name, :skipped, "期待値なし", 0, []) if wanted.empty?

      irep = compile(path)
      return Result.new(name, :error, "mrbc 失敗", 0, []) unless irep

      state = execute(irep)
      unless state[:status] == VM_FINISHED
        return Result.new(name, :error,
                          "STATUS=#{state[:status_label]} ERROR=#{state[:error]} " \
                          "PC=#{state[:pc]}", 0, [])
      end

      compare(name, wanted)
    end

    def compile(path)
      mrb = path.sub(/\.rb\z/, ".mrb")
      ok = system(@config.mrbc_path, "-o", mrb, path, out: File::NULL, err: File::NULL)
      return nil unless ok

      irep = MrbParser.new(File.binread(mrb)).parse.irep
      File.delete(mrb)
      irep
    end

    # 転送して走らせ、終わるまで待つ
    def execute(irep)
      @transfer.write_status(VM_STOPPED)
      codegen = PlcCodegen.new(irep, steps_per_cycle: @config.steps_per_cycle, layout: @layout)
      @transfer.write_image(codegen.memory_image)
      @transfer.write_fixed_image(codegen.fixed_image)
      @transfer.write_status(VM_RUNNING)

      state = nil
      POLL_LIMIT.times do
        sleep POLL_INTERVAL
        state = @transfer.read_vm_state
        break unless state[:status] == VM_RUNNING
      end
      state
    end

    def compare(name, wanted)
      checked = 0
      mismatches = []
      wanted.each do |spec, expected|
        actual = read_device(spec)
        next if actual.nil?   # デバイスでない名前は読めない

        checked += 1
        mismatches << "$#{spec} 期待 #{expected} 実際 #{actual}" unless same?(expected, actual)
      end

      return Result.new(name, :ok, "#{checked} 個", checked, []) if mismatches.empty?

      Result.new(name, :ng, "#{mismatches.size} 個ずれ", checked, mismatches)
    end

    # 実数は表示の丸めがあるので幅を持たせて比べる
    def same?(expected, actual)
      return (actual - expected).abs < 1e-5 if expected.is_a?(Float)

      actual == expected
    end

    # コンソールの `dev` と同じ経路で 1 つ読む
    def read_device(spec)
      ref = PlcCodegen.parse_device_name(spec)
      return nil unless ref
      return @adapter.read_device(ref[:device_name], ref[:address]) if ref[:bit]

      @adapter.read_device_width(ref[:device_name], ref[:address],
                                 ref[:access_type] || ACCESS_S)
    end
  end
end
