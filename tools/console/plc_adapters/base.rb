# frozen_string_literal: true

# PLC アダプター基底クラス
# 各 PLC メーカーのアダプターはこのクラスを継承して実装します。

module MrubycOnPlc
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
      end
    end
  end
end
