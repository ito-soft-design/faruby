(* faRuby probe 2d: 型を重ねる・実数の丸め方。説明は README.md
 *
 * 先にラベルを 1 つ足してください (VMD と同じ D220 に重ねます)
 *   VMX : ARRAY[0..3] OF REAL  AT D220
 *
 * TRUNC は無い。REAL_TO_INT が何をするかを見る。
 * プローブ 1 の 8 番で INT(TRUE, -2.7, d) = -3 だった *)

(* 33 同じ 2 ワードを REAL で書いて DINT で読めるか。
 * 2.5 の IEEE754 は 0x40200000 = 1075838976 *)
VMX[2] := 2.5;

(* 34 REAL_TO_INT の丸め方。
 *   -2.7 → -3 かつ 2.7 → 3 なら四捨五入
 *   -2.7 → -2 かつ 2.7 → 2 なら 0 方向へ切り捨て
 *   -2.2 が -3 なら切り下げ *)
VMF[1] := -2.7;
VMW[1] := REAL_TO_INT(VMF[1]);

VMF[2] := 2.7;
VMW[2] := REAL_TO_INT(VMF[2]);

VMF[3] := -2.2;
VMW[3] := REAL_TO_INT(VMF[3]);

(* 36 DINT の比較 *)
VMD[3] := 0;
IF VMD[0] < VMD[1] THEN
  VMD[3] := 1;
END_IF;
