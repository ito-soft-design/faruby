# test_41_device_range_melsec.rb の割り付け表 (三菱)
#
# **キーエンス版から割り付け先だけを置き換えたものです** (`DM` → `D`、
# `MR` → `M`)。プログラムの側は 1 文字も変わりません。

FaRuby.devices do
  map "regs", "D1100", 8     # D1100-1107
  map "pair", "D1110L", 4    # 32 ビット。添字はワードで数える
  map "bits", "M110", 16     # ビットデバイスの範囲 (三菱は 10 進そのまま)
end
