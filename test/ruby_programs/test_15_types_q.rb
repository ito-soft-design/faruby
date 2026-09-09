# 型タグの確認
#
# 対象機種: Q
#
# **出力先は D3000 台**です。faRuby 自身が D4000-D5999、GX Works2 の自動割付が
# D6144 以降を使うので、そこから離しています。
#
# 値だけを見ていたころは nil も false も 0 も同じで、
# if 0 が偽、nil == false が真になっていた。
#
# 期待値:
#   $D3500 = 1   0 は真 (Ruby の仕様)
#   $D3501 = 1   nil は偽
#   $D3502 = 1   false は偽
#   $D3503 = 1   nil == false は偽
#   $D3504 = 1   false == 0 は偽
#   $D3505 = -4  -7 / 2 は切り下げ
#
# 実機でのみ意味を持つ検証。

# 整数の 0 は真
zero = 0
if zero
  $D3500 = 1
else
  $D3500 = 0
end

# nil は偽
nothing = nil
if nothing
  $D3501 = 0
else
  $D3501 = 1
end

# false は偽
no = false
if no
  $D3502 = 0
else
  $D3502 = 1
end

# nil == false は偽
if nothing == no
  $D3503 = 0
else
  $D3503 = 1
end

# false == 0 は偽
if no == zero
  $D3504 = 0
else
  $D3504 = 1
end

# 整数除算は切り下げ
a = -7
b = 2
$D3505 = a / b
