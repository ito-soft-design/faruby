# flip_flop.rb — フリップ・フロップ (ND8080 / 7 セグ表示版)
#
# 原典: 「マイコンゲーム21」(岸田孝一 編, 電波新聞社, 1981)
#   8080 マシン語で書かれた「フリップ・フロップ」を
#   faRuby (mruby) で書き直したもの。
#
# ルール:
#   8 桁の 7 セグに "#" (点灯) と "o" (消灯) が表示される。
#   数字キー (1-8) で桁を選び、WRITE INC (0x15) で確定すると
#   その桁と、ランダムに割り当てられた連動桁の状態が反転する。
#   すべて消灯 ("oooooooo") にすればクリア。
#   64 手以内に消灯できなければ失敗。
#   連動パターンの組み合わせによっては全消灯が不可能な場合もある。
#   ADRS SET (0x12) を押すとギブアップして次のラウンドへ。
#
# 操作:
#   起動後、任意のキーを押すとゲーム開始。
#   1-8  : 桁を選択 (選択中の桁が点滅)
#   WR   : 確定 (選択桁と連動桁が反転)
#   ADSET: ギブアップ (次のラウンドへ)
#
# 実行:
#   rake i8080:upload SRC=examples/i8080/flip_flop.rb

@states = []
@patterns = []

puts "Push key"
while getkey 10; end  # キー離し待ち (RUN キーが押されたままの場合がある)
getkey                # キー入力待ち (待機中に乱数が回る)
while getkey 10; end  # キー離し待ち

# 現在の状態を 7 セグに表示
def print_digits
  a = ""
  8.times do |i|
    a << (@states[i] ? "#" : "o")
  end
  puts a
end

# 選択中の桁を点滅させて表示
def print_digits_and_blink hide, n
  a = ""
  8.times do |i|
    if hide && i == n
      a << " "
    else
      a << (@states[i] ? "#" : "o")
    end
  end
  puts a
end

loop do
  # 連動パターンと初期状態を生成 (全桁点灯)
  @patterns = []
  @states = []
  8.times do
    @patterns << rand(8)
    @states << true
  end

  finished = false
  64.times do
    print_digits
    k = nil

    # 数字キー (1-8) で桁を選択し、WRITE INC で確定
    set = false
    num = nil
    blink = false
    until set
      k = getkey 1000
      num = k - 1 if k && 1 <= k && k <= 8
      set = true if num && k == 0x15  # WRITE INC
      if k == 0x12                    # ADRS SET
        num = nil
        break
      end

      print_digits_and_blink blink, num
      blink = !blink
    end
    while getkey 10; end              # キー離し待ち

    break unless num    # 桁未選択ならギブアップ

    # 選択桁と連動桁の状態を反転
    @states[num] = !@states[num]
    unless @patterns[num] == num
      @states[@patterns[num]] = !@states[@patterns[num]]
    end
    print_digits

    # 全桁消灯ならクリア
    on_any = false
    @states.each do |f|
      on_any ||= f
    end
    finished = true unless on_any
    if finished
      break
    end

  end
  unless finished
    puts "________"
  end
  getkey
end
