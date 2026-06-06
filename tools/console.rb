# frozen_string_literal: true

# mruby/c on PLC コンソール
# PLC と通信して Ruby プログラムのコンパイル・転送・実行を行う対話型ツール

require "optparse"
require_relative "console/config"
require_relative "console/plc_connection"
require_relative "console/memory_transfer"
require_relative "console/commands"

module MrubycOnPlc
  module Console
    class Repl
      PROMPT = "mrubycOnPlc> "

      COMMAND_MAP = {
        "compile" => :cmd_compile,
        "load"    => :cmd_load,
        "run"     => :cmd_run,
        "status"  => :cmd_status,
        "regs"    => :cmd_regs,
        "vars"    => :cmd_vars,
        "dev"     => :cmd_dev,
        "stop"    => :cmd_stop,
        "reset"   => :cmd_reset,
        "verify"  => :cmd_verify,
        "disasm"  => :cmd_disasm,
        "sim"     => :cmd_sim,
        "connect" => :cmd_connect,
        "help"    => :cmd_help,
      }.freeze

      def initialize(config_path: nil)
        @config = Config.new(config_path)
        @adapter = PlcConnection.create(@config)
        @transfer = MemoryTransfer.new(@adapter)
        @commands = Commands.new(config: @config, adapter: @adapter, transfer: @transfer)
      end

      def run
        setup_readline
        print_banner

        loop do
          line = read_line
          break if line.nil?
          next if line.strip.empty?

          parts = line.strip.split(/\s+/, 2)
          cmd_name = parts[0].downcase
          cmd_args = parts[1]&.split(/\s+/) || []

          break if cmd_name == "quit" || cmd_name == "exit"

          method_name = COMMAND_MAP[cmd_name]
          if method_name
            begin
              @commands.send(method_name, cmd_args)
            rescue => e
              puts "ERROR: #{e.message}"
              puts e.backtrace.first(3).map { |l| "  #{l}" }.join("\n")
            end
          else
            puts "不明なコマンド: #{cmd_name} ('help' でコマンド一覧を表示)"
          end
        end

        puts "Bye!"
      end

      private

      def setup_readline
        begin
          require "readline"
          @use_readline = true
        rescue LoadError
          @use_readline = false
        end
      end

      def read_line
        if @use_readline
          Readline.readline(PROMPT, true)
        else
          print PROMPT
          $stdout.flush
          $stdin.gets&.chomp
        end
      end

      def print_banner
        puts "=== mruby/c on PLC Console ==="
        puts "PLC   : #{@config.plc_protocol} @ #{@config.plc_host}:#{@config.plc_port}"
        puts "mrbc  : #{@config.mrbc_path}"
        puts "config: #{@config.config_path || '(default)'}"
        puts "Type 'help' for available commands."
        puts
      end
    end
  end
end

if __FILE__ == $0
  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: ruby console.rb [options]"
    opts.on("--config PATH", "Config file path") { |v| options[:config_path] = v }
  end.parse!

  MrubycOnPlc::Console::Repl.new(**options).run
end
