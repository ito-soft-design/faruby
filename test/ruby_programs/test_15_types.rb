# 型タグの確認
#
# 値だけを見ていたころは nil も false も 0 も同じで、
# if 0 が偽、nil == false が真になっていた。
#
# 期待値:
#   $DM500 = 1   0 は真 (Ruby の仕様)
#   $DM501 = 1   nil は偽
#   $DM502 = 1   false は偽
#   $DM503 = 1   nil == false は偽
#   $DM504 = 1   false == 0 は偽
#   $DM505 = -4  -7 / 2 は切り下げ
#
# 実機でのみ意味を持つ検証。

# 整数の 0 は真
zero = 0
if zero
  $DM500 = 1
else
  $DM500 = 0
end

# nil は偽
nothing = nil
if nothing
  $DM501 = 0
else
  $DM501 = 1
end

# false は偽
no = false
if no
  $DM502 = 0
else
  $DM502 = 1
end

# nil == false は偽
if nothing == no
  $DM503 = 0
else
  $DM503 = 1
end

# false == 0 は偽
if no == zero
  $DM504 = 0
else
  $DM504 = 1
end

# 整数除算は切り下げ
a = -7
b = 2
$DM505 = a / b
