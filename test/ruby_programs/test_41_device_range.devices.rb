# test_41_device_range.rb の割り付け表 (キーエンス)
#
# **ワード数を渡すと添字で引ける範囲になります。** 基点が 0 でないデバイス族で、
# `$regs[0]` が DM1100、`$regs[7]` が DM1107 です。

FaRuby.devices do
  map "regs", "DM1100", 8     # DM1100-1107
  map "pair", "DM1110L", 4    # 32 ビット。添字はワードで数える
  map "bits", "MR110", 16     # ビットデバイスの範囲 (番号 26 から)
end
