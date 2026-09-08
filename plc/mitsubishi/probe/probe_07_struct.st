(* faRuby probe 7: 構造体。説明は README.md
 *
 * **見たいのは「詰め方」です。** faRuby のスロットは 4 ワード
 * (タグ 1 + 値 2 + 予備 1) で、値が奇数位置にあります。GX Works2 が
 * DINT を偶数位置に揃えるために詰め物を入れると、1 要素が 6 ワードになって
 * faRuby の配置と合いません。生の D を読んで確かめます。
 *
 * **VAL は予約語でした。** メンバ名にも接頭辞を付けます (ラベル名と同じ手)。
 * ほかにも弾かれる名前があれば、好きに変えて構いません。見ているのは
 * 詰め方であって名前ではないので。
 *
 * 先に構造体とラベルを作ってください。
 *
 *   TYPE VMSLOT : STRUCT
 *     SLTAG : INT;
 *     SLNUM : DINT;
 *     SLPAD : INT;
 *   END_STRUCT END_TYPE
 *
 *   TYPE VMSLOTF : STRUCT      同じ場所を実数で見る
 *     SLTAG : INT;
 *     SLNUM : REAL;
 *     SLPAD : INT;
 *   END_STRUCT END_TYPE
 *
 *   VMREG  : ARRAY[0..3] OF VMSLOT   AT D1100
 *   VMREGF : ARRAY[0..3] OF VMSLOTF  AT D1100
 *)

(* 37 詰め方。4 ワードなら D1100=4, D1101/D1102=123456, D1104=7 *)
VMREG[0].SLTAG := 4;
VMREG[0].SLNUM := 123456;
VMREG[0].SLPAD := 0;
VMREG[1].SLTAG := 7;
VMREG[1].SLNUM := -1;

(* 38 添字を変数で *)
VMOPA := 2;
VMREG[VMOPA].SLTAG := 9;
VMREG[VMOPA].SLNUM := 555;

(* 39 同じ場所を実数で見られるか。2.5 は 0x40200000 = 1075838976 *)
VMREGF[3].SLNUM := 2.5;

(* 40 構造体どうしの写し (OP_MOVE に当たる) *)
VMREG[1].SLNUM := VMREG[0].SLNUM;
VMREG[1].SLTAG := VMREG[0].SLTAG;
