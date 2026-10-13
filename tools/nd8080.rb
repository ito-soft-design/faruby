# ND8080 メモリ読み書きツール
#   ruby nd8080.rb info                         接続確認
#   ruby nd8080.rb dump  8000 80FF              メモリを16進表示
#   ruby nd8080.rb save  8000 80FF out.btk      メモリをファイルへ保存 (.btk / .bin)
#   ruby nd8080.rb load  prog.btk               BTK ファイルをメモリへ書き込み
#   ruby nd8080.rb load  prog.bin 8000          BIN ファイルを指定アドレスへ書き込み
#   ruby nd8080.rb poke  8000 3E 50 FF          指定アドレスへバイトを書き込み
#   ruby nd8080.rb run   8000                   指定アドレスから実行
#   load / poke に --verify を付けると書き込み後に読み戻して照合します
require_relative "nd8080_hid"

def hex(s) = Integer(s, 16)

def hexdump(adrs, data)
  data.bytes.each_slice(16).with_index do |row, i|
    a = adrs + i * 16
    asc = row.map { |b| (0x20..0x7e).cover?(b) ? b.chr : "." }.join
    puts format("%04X  %-48s %s", a, row.map { |b| format("%02X ", b) }.join, asc)
  end
end

def btk_of(adrs, data) = [adrs, adrs + data.bytesize - 1].pack("nn") + data.b

def verify(r, btk)
  s, e = btk.unpack("nn")
  back = r.save(s, e)
  if back == btk
    puts "照合OK"
  else
    diff = (4...btk.bytesize).find { |i| back.getbyte(i) != btk.getbyte(i) }
    abort format("照合NG: %04X 番地 書込=%02X 読出=%02X", s + diff - 4, btk.getbyte(diff), back.getbyte(diff))
  end
end

cmd, *args = ARGV
verify_opt = args.delete("--verify")
abort File.read(__FILE__, encoding: "UTF-8").lines.take_while { |l| l.start_with?("#") }.join if cmd.nil?

begin
  if cmd == "info"
    dev = ND8080.open_device
    puts "ND8080 を検出しました: #{dev.path}  [#{dev.class.name.split("::").last}]"
    puts "バージョン 0x%04X / 入力 %d バイト / 出力 %d バイト" % [dev.version, dev.input_len, dev.output_len]
    dev.close
    exit
  end

  r = ND8080::Remote.new
  r.on_text = nil unless cmd == "run"
  r.connect

  case cmd
  when "dump"
    s, e = hex(args[0]), hex(args[1] || args[0])
    hexdump(s, r.save(s, e)[4..])
  when "save"
    file = args[2] or abort "ファイル名を指定してください"
    s, e = hex(args[0]), hex(args[1])
    btk = r.save(s, e)
    File.binwrite(file, file =~ /\.bin\z/i ? btk[4..] : btk)
    puts format("保存しました: %s  (%04X-%04X, %d バイト)", file, s, e, e - s + 1)
  when "load"
    file = args[0] or abort "ファイル名を指定してください"
    raw = File.binread(file)
    btk = args[1] ? btk_of(hex(args[1]), raw) : raw
    s, e = btk.unpack("nn")
    abort "BTK ファイルのサイズがアドレス範囲と合いません" if btk.bytesize != e - s + 5
    r.load(btk)
    puts format("書き込みました: %s  (%04X-%04X, %d バイト)", file, s, e, e - s + 1)
    verify(r, btk) if verify_opt
  when "poke"
    adrs = hex(args.shift)
    btk = btk_of(adrs, args.map { |b| hex(b) }.pack("C*"))
    r.load(btk)
    puts format("%04X 番地から %d バイト書き込みました", adrs, args.size)
    verify(r, btk) if verify_opt
  when "run"
    r.run(hex(args[0]))
    puts format("%04X から実行しました (Ctrl+C で終了)", hex(args[0]))
    loop { r.drain(1) }
  else
    abort "不明なコマンド: #{cmd}"
  end
  r.close
rescue ND8080::Timeout => e
  abort "#{e.message}\nND8080 が ND80Z モニタで動作しているか確認してください。"
rescue Interrupt
  puts
rescue RuntimeError, ArgumentError => e
  abort e.message
end
