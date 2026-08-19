# frozen_string_literal: true

# PLC アダプター基底クラス
# 各 PLC メーカーのアダプターはこのクラスを継承して実装します。

require_relative "../../memory_map"

module FaRuby
  module Console
    module PlcAdapters
      class Base
        def connect
          raise NotImplementedError
        end

        def disconnect
          raise NotImplementedError
        end

        def connected?
          raise NotImplementedError
        end

        # 16ビットワードを1つ読み出す
        def read_word(addr)
          raise NotImplementedError
        end

        # 16ビットワードを1つ書き込む
        def write_word(addr, value)
          raise NotImplementedError
        end

        # 連続する count ワードを読み出す
        def read_words(addr, count)
          raise NotImplementedError
        end

        # 連続するワードを書き込む
        def write_words(addr, values)
          raise NotImplementedError
        end

        # デバイス名 ("EM", "D" 等)
        def device_name
          raise NotImplementedError
        end

        # 任意デバイスの読み取り (例: "DM", 100) — 16ビット1ワード
        def read_device(device_prefix, addr)
          raise NotImplementedError
        end

        # 任意デバイスの書き込み — 16ビット1ワード
        def write_device(device_prefix, addr, value)
          raise NotImplementedError
        end

        # ワードデバイスを32ビット符号付きで読む (連続2ワード、下位が先)
        def read_device_long(device_prefix, addr)
          raise NotImplementedError
        end

        # ワードデバイスに32ビット符号付きで書き込む (連続2ワード、下位が先)
        def write_device_long(device_prefix, addr, value)
          raise NotImplementedError
        end

        # ACCESS_* のアクセス幅でワードデバイスを読む
        # VM (GETGV) と同じ幅で読むことでコンソール表示を一致させる
        def read_device_width(device_prefix, addr, access_type)
          case access_type
          when MemoryMap::ACCESS_U
            read_device(device_prefix, addr)
          when MemoryMap::ACCESS_L
            read_device_long(device_prefix, addr)
          when MemoryMap::ACCESS_D
            read_device_long(device_prefix, addr) & 0xFFFF_FFFF
          else # ACCESS_S
            v = read_device(device_prefix, addr)
            v >= 0x8000 ? v - 0x1_0000 : v
          end
        end

        # ACCESS_* のアクセス幅でワードデバイスに書く
        def write_device_width(device_prefix, addr, access_type, value)
          case access_type
          when MemoryMap::ACCESS_L, MemoryMap::ACCESS_D
            write_device_long(device_prefix, addr, value)
          else # ACCESS_S / ACCESS_U
            write_device(device_prefix, addr, value.to_i & 0xFFFF)
          end
        end

        private

        # 下位/上位ワードから32ビット符号付き値を組み立てる
        def compose_s32(lo, hi)
          val = ((hi & 0xFFFF) << 16) | (lo & 0xFFFF)
          val >= 0x8000_0000 ? val - 0x1_0000_0000 : val
        end

        # 32ビット符号付き値を [下位, 上位] のワード列に分解する
        def split_s32(value)
          val = value.to_i
          val += 0x1_0000_0000 if val.negative?
          [val & 0xFFFF, (val >> 16) & 0xFFFF]
        end
      end
    end
  end
end
