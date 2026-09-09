# frozen_string_literal: true

# 三菱 MELSEC 用 PLC アダプター
# plc_access gem の McProtocol を使用して通信します。

require "plc_access"
require_relative "base"

module FaRuby
  module Console
    module PlcAdapters
      # **キーエンス版との違いはプロトコルと既定のデバイスだけ**です。
      # 読み書きの形はどちらも `plc["D100", 2]` で揃っています。
      #
      # 固定領域は KV が FM (ZF のバンク) でしたが、三菱は ZR です。バンクが
      # 無いので、ホストとスクリプトでアドレスが食い違いません
      # (doc/melsec.md)。
      class MitsubishiMc < Base
        DEFAULT_DEVICE = "D"

        def initialize(host:, port: 5010, device_name: DEFAULT_DEVICE)
          @host = host
          @port = port
          @device_name = device_name
          @plc = nil
        end

        def connect
          @plc = PlcAccess::Protocol::Mitsubishi::McProtocol.new(host: @host, port: @port)
        end

        def disconnect
          begin
            @plc&.close
          rescue StandardError
            nil
          end
          @plc = nil
        end

        def connected? = !@plc.nil?

        attr_reader :device_name

        def read_word(addr) = read_device(device_name, addr)
        def write_word(addr, value) = write_device(device_name, addr, value)
        def read_words(addr, count) = read_device_words(device_name, addr, count)
        def write_words(addr, values) = write_device_words(device_name, addr, values)

        def read_device(device_prefix, addr)
          ensure_connected
          @plc["#{device_prefix}#{addr}"]
        end

        def write_device(device_prefix, addr, value)
          ensure_connected
          @plc["#{device_prefix}#{addr}"] = value
        end

        def read_device_words(device_prefix, addr, count)
          ensure_connected
          @plc["#{device_prefix}#{addr}", count]
        end

        def write_device_words(device_prefix, addr, values)
          ensure_connected
          @plc["#{device_prefix}#{addr}", values.size] = values
        end

        def read_device_long(device_prefix, addr)
          lo, hi = read_device_words(device_prefix, addr, 2)
          compose_s32(lo, hi)
        end

        def write_device_long(device_prefix, addr, value)
          write_device_words(device_prefix, addr, split_s32(value))
        end

        private

        def ensure_connected
          connect unless connected?
        end
      end
    end
  end
end
