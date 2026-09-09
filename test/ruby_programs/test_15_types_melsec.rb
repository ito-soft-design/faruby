# 型タグの確認
#
# 対象機種: Q, iQ-R
#
# **キーエンス版から機種名だけを置き換えたものです** (`DM` → `D`、`MR` → `M`)。
# アドレスはそのままで、faRuby の D4000-D5999 とも GX Works2 が一時変数に使う
# D6144 以降とも重なりません。
#
# 値だけを見ていたころは nil も false も 0 も同じで、
# if 0 が偽、nil == false が真になっていた。
#
# 期待値:
#   $D500 = 1   0 は真 (Ruby の仕様)
#   $D501 = 1   nil は偽
#   $D502 = 1   false は偽
#   $D503 = 1   nil == false は偽
#   $D504 = 1   false == 0 は偽
#   $D505 = -4  -7 / 2 は切り下げ
#
# 実機でのみ意味を持つ検証。

# 整数の 0 は真
zero = 0
if zero
  $D500 = 1
else
  $D500 = 0
end

# nil は偽
nothing = nil
if nothing
  $D501 = 0
else
  $D501 = 1
end

# false は偽
no = false
if no
  $D502 = 0
else
  $D502 = 1
end

# nil == false は偽
if nothing == no
  $D503 = 0
else
  $D503 = 1
end

# false == 0 は偽
if no == zero
  $D504 = 0
else
  $D504 = 1
end

# 整数除算は切り下げ
a = -7
b = 2
$D505 = a / b
