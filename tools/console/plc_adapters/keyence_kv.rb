# frozen_string_literal: true

# Keyence KV シリーズ用 PLC アダプター
# plc_access gem の KvProtocol を使用して通信します。

require "plc_access"
require_relative "base"

module MrubycOnPlc
  module Console
    module PlcAdapters
      class KeyenceKv < Base
        DEVICE_PREFIX = "EM"

        def initialize(host:, port: 8501)
          @host = host
          @port = port
          @plc = nil
        end

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
          @plc["#{DEVICE_PREFIX}#{addr}"]
        end

        def write_word(addr, value)
          ensure_connected
          @plc["#{DEVICE_PREFIX}#{addr}"] = value
        end

        def read_words(addr, count)
          ensure_connected
          @plc["#{DEVICE_PREFIX}#{addr}", count]
        end

        def write_words(addr, values)
          ensure_connected
          @plc["#{DEVICE_PREFIX}#{addr}", values.size] = values
        end

        def device_name
          DEVICE_PREFIX
        end

        def read_device(device_prefix, addr)
          ensure_connected
          @plc["#{device_prefix}#{addr}"]
        end

        def write_device(device_prefix, addr, value)
          ensure_connected
          @plc["#{device_prefix}#{addr}"] = value
        end

        def read_device_long(device_prefix, addr)
          ensure_connected
          lo, hi = @plc["#{device_prefix}#{addr}", 2]
          compose_s32(lo, hi)
        end

        def write_device_long(device_prefix, addr, value)
          ensure_connected
          @plc["#{device_prefix}#{addr}", 2] = split_s32(value)
        end

        private

        def ensure_connected
          connect unless connected?
        end
      end
    end
  end
end
