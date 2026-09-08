# ビットデバイスの読み書き
#
# **書き込みは TRUE / FALSE の代入です。** 以前はタイマ・カウンタだけ
# `SET` / `RES`、他は 1 / 0 の代入に分かれていました。
#
# 整数を書くと非 0 が ON になります。読むと真偽値になるので、`if $MR10` が
# 期待どおりに働きます (整数の 0 は Ruby では真なので、整数のままだと
# 常に成立してしまいます)。
#
# タイマ・カウンタは機種によって使えないため、test_33_timer_counter.rb に
# 分けてあります。
#
# 期待値:
#   $DM120 = 1       $MR10 = 1 (非0) → ON
#   $DM121 = 1       $MR11 = true → ON
#   $DM122 = 1       $MR200 = 43 (非0) → ON
#   $DM123 = 1       $R300 = true → ON
#   $DM124 = 0       $B400 = false → OFF
#   $DM125 = 0       $LR500 = 0 → OFF
#
# 実機でのみ意味を持つ検証。

$MR10 = false
$MR11 = false
$MR200 = false
$R300 = false
$B400 = true
$LR500 = true

$DM100 = 42
$MR10 = 1
$MR11 = true
$MR200 = $DM100 + $MR10
$R300 = true
$B400 = false
$LR500 = 0

$DM120 = 0
$DM120 = 1 if $MR10
$DM121 = 0
$DM121 = 1 if $MR11
$DM122 = 0
$DM122 = 1 if $MR200
$DM123 = 0
$DM123 = 1 if $R300
$DM124 = 0
$DM124 = 1 if $B400
$DM125 = 0
$DM125 = 1 if $LR500
