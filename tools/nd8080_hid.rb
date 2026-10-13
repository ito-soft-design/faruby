# ND8080 (中日電工) USB-HID アクセス用ライブラリ (Windows / macOS / Linux)
# 追加 gem 不要。HID の読み書きは次のどちらかを Fiddle で直接呼び出す。
#   hidapi  : macOS・Linux・Windows 共通 (macOS は `brew install hidapi`)
#   Windows : hidapi が無いときは Windows 標準の hid.dll / setupapi.dll
# 環境変数 ND8080_BACKEND=hidapi または windows で使う方を固定できる。
# 環境変数 ND8080_HIDAPI に hidapi ライブラリのパスを指定することもできる。
require "fiddle"
require "fiddle/import"
require "rbconfig"

module ND8080
  VID = 0x20A0
  PID = 0x422C
  REPORT_LEN = 64 # レポートIDを除いたデータ長 (送受信とも)

  def self.windows? = RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/)

  # 使えるバックエンドで ND8080 を開く
  def self.open_device
    case ENV["ND8080_BACKEND"]
    when "hidapi" then HidapiDevice.new
    when "windows" then WinDevice.new
    else
      if HidapiDevice.available? then HidapiDevice.new
      elsif windows? then WinDevice.new
      else raise "hidapi が見つかりません。macOS では `brew install hidapi` を実行してください。"
      end
    end
  end

  # ---------------------------------------------------------------- hidapi
  module Hidapi
    CANDIDATES =
      if ND8080.windows? then %w[hidapi.dll libhidapi-0.dll]
      elsif RbConfig::CONFIG["host_os"].match?(/darwin/)
        %w[/opt/homebrew/lib/libhidapi.dylib /usr/local/lib/libhidapi.dylib libhidapi.dylib libhidapi.0.dylib]
      else %w[libhidapi-hidraw.so.0 libhidapi-hidraw.so libhidapi-libusb.so.0]
      end

    class << self
      attr_reader :enumerate, :free_enum, :open_path, :write, :read_timeout, :close

      def load
        return @loaded unless @loaded.nil?
        paths = ENV["ND8080_HIDAPI"] ? [ENV["ND8080_HIDAPI"]] : CANDIDATES
        lib = paths.lazy.map { |p| Fiddle.dlopen(p) rescue nil }.find(&:itself)
        return @loaded = false unless lib
        f = ->(name, args, ret) { Fiddle::Function.new(lib[name], args, ret) }
        v, i, s, us = Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_SIZE_T, -Fiddle::TYPE_SHORT
        @enumerate    = f.("hid_enumerate", [us, us], v)
        @free_enum    = f.("hid_free_enumeration", [v], Fiddle::TYPE_VOID)
        @open_path    = f.("hid_open_path", [v], v)
        @write        = f.("hid_write", [v, v, s], i)
        @read_timeout = f.("hid_read_timeout", [v, v, s, i], i)
        @close        = f.("hid_close", [v], Fiddle::TYPE_VOID)
        f.("hid_init", [], i).call
        @loaded = true
      end
    end
  end

  class HidapiDevice
    attr_reader :path, :version

    def self.available? = Hidapi.load

    def initialize
      raise "hidapi が読み込めません" unless Hidapi.load
      list = Hidapi.enumerate.call(VID, PID)
      raise "ND8080 が見つかりません (VID_20A0&PID_422C)" if list.null?
      # struct hid_device_info (64bit): char *path; u16 vid; u16 pid; wchar_t *serial; u16 release_number; ...
      @path = Fiddle::Pointer.new(list[0, 8].unpack1("Q")).to_s
      @version = list[24, 2].unpack1("S")
      Hidapi.free_enum.call(list)
      @h = Hidapi.open_path.call(@path)
      raise "デバイスを開けません: #{@path}" if @h.null?
    end

    def input_len = REPORT_LEN + 1
    def output_len = REPORT_LEN + 1

    # 64 バイトのデータを送信 (先頭にレポートID 0 を付けて送る)
    def write(data)
      bytes = data.b
      raise "データが長すぎます" if bytes.bytesize > REPORT_LEN
      report = "\0".b + bytes + "\0".b * (REPORT_LEN - bytes.bytesize)
      n = Hidapi.write.call(@h, report, report.bytesize)
      n < 0 ? nil : n
    end

    # 1 レポート受信。timeout ミリ秒で届かなければ nil。レポートIDを除いたデータを返す
    # (hidapi はレポートIDを使わないデバイスでは先頭のIDを付けずに返す)
    def read(timeout = 1000)
      buf = "\0".b * REPORT_LEN
      n = Hidapi.read_timeout.call(@h, buf, buf.bytesize, timeout)
      n > 0 ? buf[0, n] : nil
    end

    def close = Hidapi.close.call(@h)
  end

  # ---------------------------------------------------------------- Windows 標準 API
  if windows?
    module Win
      extend Fiddle::Importer
      dlload "kernel32.dll", "setupapi.dll", "hid.dll"
      typealias "HANDLE", "void*"
      typealias "DWORD", "unsigned long"
      typealias "BOOL", "int"

      extern "void HidD_GetHidGuid(void*)"
      extern "BOOL HidD_GetAttributes(HANDLE, void*)"
      extern "BOOL HidD_GetPreparsedData(HANDLE, void*)"
      extern "BOOL HidD_FreePreparsedData(void*)"
      extern "long HidP_GetCaps(void*, void*)"
      extern "HANDLE SetupDiGetClassDevsW(void*, void*, void*, DWORD)"
      extern "BOOL SetupDiEnumDeviceInterfaces(HANDLE, void*, void*, DWORD, void*)"
      extern "BOOL SetupDiGetDeviceInterfaceDetailW(HANDLE, void*, void*, DWORD, void*, void*)"
      extern "BOOL SetupDiDestroyDeviceInfoList(HANDLE)"
      extern "HANDLE CreateFileW(void*, DWORD, DWORD, void*, DWORD, DWORD, HANDLE)"
      extern "BOOL ReadFile(HANDLE, void*, DWORD, void*, void*)"
      extern "BOOL WriteFile(HANDLE, void*, DWORD, void*, void*)"
      extern "BOOL CloseHandle(HANDLE)"
      extern "BOOL CancelIo(HANDLE)"
      extern "DWORD GetLastError()"
      extern "HANDLE CreateEventW(void*, BOOL, BOOL, void*)"
      extern "BOOL ResetEvent(HANDLE)"
      extern "DWORD WaitForSingleObject(HANDLE, DWORD)"
      extern "BOOL GetOverlappedResult(HANDLE, void*, void*, BOOL)"

      GENERIC_RW = 0xC0000000
      FILE_SHARE_RW = 0x3
      OPEN_EXISTING = 3
      FILE_FLAG_OVERLAPPED = 0x40000000
      DIGCF_PRESENT_INTERFACE = 0x12
      INVALID_HANDLE = (1 << 64) - 1
      WAIT_TIMEOUT = 0x102

      def self.wstr(s) = (s + "\0").encode("UTF-16LE")
      def self.from_wbuf(b) = b.force_encoding("UTF-16LE").encode("UTF-8").split("\0").first.to_s

      # 接続中の ND8080 のデバイスパスを列挙
      def self.device_paths
        guid = "\0" * 16
        HidD_GetHidGuid(guid)
        info = SetupDiGetClassDevsW(guid, nil, nil, DIGCF_PRESENT_INTERFACE)
        paths = []
        i = 0
        loop do
          ifd = [32].pack("L") + "\0" * 28 # SP_DEVICE_INTERFACE_DATA (x64)
          break if SetupDiEnumDeviceInterfaces(info, nil, guid, i, ifd) == 0
          i += 1
          need = [0].pack("L")
          SetupDiGetDeviceInterfaceDetailW(info, ifd, nil, 0, need, nil)
          size = need.unpack1("L")
          detail = [8].pack("L") + "\0" * (size - 4) # cbSize = 8 (x64)
          next if SetupDiGetDeviceInterfaceDetailW(info, ifd, detail, size, nil, nil) == 0
          path = from_wbuf(detail[4..])
          paths << path if path =~ /vid_#{"%04x" % VID}&pid_#{"%04x" % PID}/i
        end
        SetupDiDestroyDeviceInfoList(info)
        paths
      end
    end
  end

  class WinDevice
    attr_reader :path, :input_len, :output_len, :version

    def initialize(path = Win.device_paths.first)
      raise "ND8080 が見つかりません (VID_20A0&PID_422C)" unless path
      @path = path
      @h = Win.CreateFileW(Win.wstr(path), Win::GENERIC_RW, Win::FILE_SHARE_RW,
                           nil, Win::OPEN_EXISTING, Win::FILE_FLAG_OVERLAPPED, nil)
      raise "デバイスを開けません (error #{Win.GetLastError})" if @h.to_i == Win::INVALID_HANDLE
      @event = Win.CreateEventW(nil, 1, 0, nil)
      read_info
    end

    # 64 バイトのデータを送信 (先頭にレポートID 0 を付けて送る)
    def write(data)
      bytes = data.b
      raise "データが長すぎます" if bytes.bytesize > @output_len - 1
      report = "\0".b + bytes + "\0".b * (@output_len - 1 - bytes.bytesize)
      io(:WriteFile, report, 1000)
    end

    # 1 レポート受信。timeout ミリ秒で届かなければ nil。レポートIDを除いたデータを返す
    def read(timeout = 1000)
      buf = "\0".b * @input_len
      n = io(:ReadFile, buf, timeout)
      n ? buf[1, n - 1] : nil
    end

    def close
      Win.CloseHandle(@event)
      Win.CloseHandle(@h)
    end

    private

    def read_info
      attr = [12].pack("L") + "\0" * 8
      Win.HidD_GetAttributes(@h, attr)
      @version = attr.unpack("LSSS")[3]
      pp_ptr = "\0" * 8
      Win.HidD_GetPreparsedData(@h, pp_ptr)
      pdata = pp_ptr.unpack1("Q")
      caps = "\0" * 64
      Win.HidP_GetCaps(pdata, caps)
      Win.HidD_FreePreparsedData(pdata)
      @input_len, @output_len = caps.unpack("SSSSS")[2, 2]
    end

    def io(func, buf, timeout)
      Win.ResetEvent(@event)
      ov = "\0" * 24 + [@event.to_i].pack("Q") # OVERLAPPED (x64)
      done = [0].pack("L")
      Win.send(func, @h, buf, buf.bytesize, nil, ov)
      if Win.WaitForSingleObject(@event, timeout) == Win::WAIT_TIMEOUT
        Win.CancelIo(@h)
        Win.GetOverlappedResult(@h, ov, done, 1)
        return nil
      end
      Win.GetOverlappedResult(@h, ov, done, 0) == 0 ? nil : done.unpack1("L")
    end
  end
end

module ND8080
  # ND8080 のキーコード (公式 n8zb3_1b.cpp より)
  module Key
    RUN = 0x10; CONT = 0x11; ADRS_SET = 0x12; RD_DEC = 0x13; RD_INC = 0x14; WR_INC = 0x15
    IO_MODE = 0x16; REG_MODE = 0x17
    # I/O モードの後に送るサブコマンド
    IO_SO = 0x02; IO_SI = 0x03; IO_TRACE = 0x04; IO_MOVE = 0x09; IO_DUMP = 0x0A
    IO_SAVE = 0x0C; IO_LOAD = 0x0D; IO_OUT = 0x0E; IO_IN = 0x0F
  end

  class Timeout < StandardError; end

  # ND80Z モニタのリモート操作 (公式 n8zb3 と同じ手順)
  #  受信: [通番][個数][データ…]。通番が変わったら F0 通番 を返して受信を知らせる。
  #  データは [長さ][中身] の並び。長さ0=キー入力待ち、4=表示(アドレス,データ)、その他=文字
  #  送信: [個数][キーコード…]
  class Remote
    attr_reader :display
    attr_accessor :on_text, :on_display

    def initialize(dev = ND8080.open_device)
      @dev = dev
      @seq = 0
      @buf = "".b
      @display = nil
      @on_text = ->(s) { $stdout.print s.force_encoding("CP932").encode("UTF-8", invalid: :replace, undef: :replace) }
      @on_display = nil
    end

    def close = @dev.close

    # リモート接続開始。ND8080 側で [*(I/O)][8] を押してリモート ON にすると
    # キー入力待ちが届くので、公式 n8zb3 と同じく RD+ を送って開始する
    def connect(timeout = 60)
      if wait_ready(0.5, raise_on_timeout: false)
        key(Key::RD_INC)
        return self
      end
      # 前回の接続でリモート ON のままなら、キーを送ると応答が返る
      send_bytes([Key::RD_INC])
      return self if wait_ready(1, raise_on_timeout: false)
      $stderr.puts "ND8080 で [＊(I/O)] → [8] を押してリモート機能を ON にしてください…"
      wait_ready(timeout)
      key(Key::RD_INC)
      self
    end

    # 1キー送信して入力待ちに戻るまで待つ
    def key(code, timeout = 3)
      send_bytes([code])
      wait_ready(timeout)
    end

    def hex_keys(value, digits = 4)
      format("%0#{digits}X", value).each_char { |c| key(c.to_i(16)) }
    end

    def set_address(adrs)
      hex_keys(adrs)
      key(Key::ADRS_SET)
    end

    # I/O モードに入ってサブコマンドを送る (応答待ちはしない)
    def io_command(sub)
      key(Key::IO_MODE)
      drain(0.1)
      send_bytes([sub])
    end

    # メモリ読み出し。BTK 形式 (先頭4バイト=開始/終了アドレス) の文字列を返す
    def save(sadrs, eadrs, timeout: 30)
      raise ArgumentError, "終了アドレスが開始アドレスより小さい" if eadrs < sadrs
      set_address(sadrs)
      hex_keys(eadrs)
      io_command(Key::IO_SAVE)
      expect = eadrs - sadrs + 5
      data = "".b
      deadline = Time.now + timeout
      loop do
        raise Timeout, "SAVE の受信がタイムアウトしました (#{data.bytesize}/#{expect} バイト)" if Time.now > deadline
        poll(50)
        while (c = next_chunk)
          type, body = c
          if type == :ready
            raise "受信データが不足しています (#{data.bytesize}/#{expect} バイト)" if data.bytesize < expect
            return data[0, expect]
          end
          data << body
        end
      end
    end

    # メモリ書き込み。btk = 先頭4バイトにアドレスが入った BTK 形式の文字列
    def load(btk, timeout: 30)
      io_command(Key::IO_LOAD)
      btk.b.bytes.each_slice(63) { |s| send_bytes(s) }
      wait_ready(timeout)
    end

    def run(adrs)
      set_address(adrs)
      send_bytes([Key::RUN])
    end

    # 受信して文字・表示を処理し、キー入力待ちが来たら true
    def wait_ready(timeout = 3, raise_on_timeout: true)
      deadline = Time.now + timeout
      while Time.now < deadline
        poll(50)
        while (c = next_chunk)
          return true if handle(c) == :ready
        end
      end
      raise Timeout, "ND8080 から応答がありません" if raise_on_timeout
      false
    end

    # 一定時間受信して表示だけ処理する
    def drain(sec)
      deadline = Time.now + sec
      while Time.now < deadline
        poll(20)
        while (c = next_chunk) do handle(c) end
      end
    end

    private

    def handle((type, body))
      case type
      when :display
        @display = body.unpack("nn")
        @on_display&.call(*@display)
      when :text
        @on_text&.call(body.dup)
      end
      type
    end

    def send_bytes(bytes)
      raise ArgumentError if bytes.size > 63
      @dev.write([bytes.size, *bytes].pack("C*")) or raise "送信エラー"
    end

    def poll(timeout)
      r = @dev.read(timeout) or return
      seq, cnt = r.getbyte(0), r.getbyte(1)
      return if seq == @seq
      @dev.write([0xF0, seq].pack("C*")) # 受信済みマーク
      @seq = seq
      @buf << r[2, cnt] if cnt.between?(1, r.bytesize - 2)
    end

    def next_chunk
      return nil if @buf.empty?
      len = @buf.getbyte(0)
      return nil if @buf.bytesize < len + 1
      body = @buf[1, len]
      @buf = @buf[(len + 1)..]
      [len.zero? ? :ready : (len == 4 ? :display : :text), body]
    end
  end
end
