# frozen_string_literal: true

# Keyence KV シリーズ用 PLC アダプター
# plc_access gem の KvProtocol を使用して通信します。

require "plc_access"
require_relative "base"

module FaRuby
  module Console
    module PlcAdapters
      class KeyenceKv < Base
        DEVICE_PREFIX = "EM"

        def initialize(host:, port: 8501)
          @host = host
          @port = port
          @plc = nil
        end

        attr_reader :host, :port


        def connect
          @plc = PlcAccess::Protocol::Keyence::KvProtocol.new(host: @host, port: @port)
        end

        def disconnect
          @plc&.close rescue nil
          @plc = nil
        end

        def connected?
          !@plc.nil?
        end

        def read_word(addr)
          ensure_connected
          through { @plc["#{DEVICE_PREFIX}#{addr}"] }
        end

        def write_word(addr, value)
          ensure_connected
          through { @plc["#{DEVICE_PREFIX}#{addr}"] = value }
        end

        def read_words(addr, count)
          read_device_words(DEVICE_PREFIX, addr, count)
        end

        def write_words(addr, values)
          write_device_words(DEVICE_PREFIX, addr, values)
        end

        def read_device_words(device_prefix, addr, count)
          ensure_connected
          through { @plc["#{device_prefix}#{addr}", count] }
        end

        def write_device_words(device_prefix, addr, values)
          ensure_connected
          through { @plc["#{device_prefix}#{addr}", values.size] = values }
        end

        def device_name
          DEVICE_PREFIX
        end

        def read_device(device_prefix, addr)
          ensure_connected
          through { @plc["#{device_prefix}#{addr}"] }
        end

        def write_device(device_prefix, addr, value)
          ensure_connected
          through { @plc["#{device_prefix}#{addr}"] = value }
        end

        def read_device_long(device_prefix, addr)
          ensure_connected
          lo, hi = @plc["#{device_prefix}#{addr}", 2]
          compose_s32(lo, hi)
        end

        def write_device_long(device_prefix, addr, value)
          ensure_connected
          through { @plc["#{device_prefix}#{addr}", 2] = split_s32(value) }
        end

        private

        def ensure_connected
          connect unless connected?
        end

        # **plc_access は繋がらないまま先へ進みます。** nil に対する
        # 呼び出しになって初めて落ちるので、ここで元の話に戻します
        def through
          yield
        rescue NoMethodError => e
          raise unless e.message.include?("nil")

          unreachable(e)
        end
      end
    end
  end
end
