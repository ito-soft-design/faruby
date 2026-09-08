(* faRuby probe 6: 本物の一切れ。オペコード 0x00-0x07 (KV の vm_05_group1)
 *
 * **ステップ数を測るためのものです。** 入れる前と後で使用量を引き算します。
 * 動かす必要はありません (バイトコードが空なので何もしません)。
 *
 * **ラベル名はデバイス名に見えてはいけません。** B / W / X / Y などは 16 進
 * アドレスなので、BC は B デバイスの 0x0C と読まれます。PC も P (ポインタ) の
 * 0x0C です。そこで全部 VM を頭に付けています。
 *
 * 先に下のラベルを作ってください。**大きさは測定に影響しません。**
 *
 *   VMPC   : INT   AT D400   プログラムカウンタ
 *   VMOP   : INT   AT D401   実行中のオペコード番号
 *   VMOPA  : INT   AT D402   オペランド a
 *   VMOPB  : INT   AT D403   オペランド b
 *   VMDSP  : INT   AT D404   振り分け用の番号
 *   VMST   : INT   AT D405   STATUS
 *   VMERR  : INT   AT D406   ERROR
 *   VMLEN  : INT   AT D407   バイトコード長
 *   VMLOOP : INT   AT D408   BREAK の相手にする FOR
 *
 *   VMBC  : ARRAY[0..255] OF INT   AT D500    バイトコード
 *   VMRT  : ARRAY[0..31]  OF INT   AT D800    レジスタの型タグ
 *   VMRV  : ARRAY[0..31]  OF DINT  AT D850    レジスタの値 (32 ビット)
 *   VMRF  : ARRAY[0..31]  OF REAL  AT D850    同じ場所を実数で
 *   VMPLT : ARRAY[0..15]  OF INT   AT D950    定数プールの型
 *   VMPLV : ARRAY[0..15]  OF DINT  AT D970    定数プールの値
 *
 * KV との違い:
 *   KV   Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;  EM1.L:Z1 := EM1.L:Z2;
 *   三菱 VMRV[VMOPA] := VMRV[VMOPB];
 * 配列の添字がそのままレジスタ番号なので、アドレス計算が要りません。
 *)

IF VMDSP <= 7 THEN

  (* KV は 65535 で潰していたが、MELSEC の INT は符号付きなので入らない。
   * -1 にすると IF VMDSP <= 7 が真になって壊れる。大きい正の数を使う *)
  VMDSP := 32767;

  FOR VMLOOP := 1 TO 1 DO

    IF VMOP = 0 THEN
      (* OP_NOP *)
      ;

    ELSIF VMOP = 1 THEN
      (* OP_MOVE (BB): R[a] = R[b] *)
      VMOPA := VMBC[VMPC];
      VMPC := VMPC + 1;
      VMOPB := VMBC[VMPC];
      VMPC := VMPC + 1;
      VMRV[VMOPA] := VMRV[VMOPB];
      VMRT[VMOPA] := VMRT[VMOPB];

    ELSIF VMOP = 2 THEN
      (* OP_LOADL (BB): R[a] = Pool[b] *)
      VMOPA := VMBC[VMPC];
      VMPC := VMPC + 1;
      VMOPB := VMBC[VMPC];
      VMPC := VMPC + 1;
      VMRV[VMOPA] := VMPLV[VMOPB];
      VMRT[VMOPA] := VMPLT[VMOPB];

    ELSIF VMOP = 3 THEN
      (* OP_LOADI (BB): R[a] = b *)
      VMOPA := VMBC[VMPC];
      VMPC := VMPC + 1;
      VMOPB := VMBC[VMPC];
      VMPC := VMPC + 1;
      VMRV[VMOPA] := INT_TO_DINT(VMOPB);
      VMRT[VMOPA] := 4;

    ELSIF VMOP = 4 THEN
      (* OP_LOADINEG (BB): R[a] = -b
       * KV は 2 の補数を 16 ビット 2 つで組み立てるが、DINT なら 1 文。
       * ただし INT から DINT へは明示的な変換が要る *)
      VMOPA := VMBC[VMPC];
      VMPC := VMPC + 1;
      VMOPB := VMBC[VMPC];
      VMPC := VMPC + 1;
      VMRV[VMOPA] := 0 - INT_TO_DINT(VMOPB);
      VMRT[VMOPA] := 4;

    ELSIF VMOP = 5 THEN
      (* OP_LOADI__1 (B): R[a] = -1 *)
      VMOPA := VMBC[VMPC];
      VMPC := VMPC + 1;
      VMRV[VMOPA] := -1;
      VMRT[VMOPA] := 4;

    ELSIF VMOP = 6 THEN
      (* OP_LOADI_0 (B): R[a] = 0 *)
      VMOPA := VMBC[VMPC];
      VMPC := VMPC + 1;
      VMRV[VMOPA] := 0;
      VMRT[VMOPA] := 4;

    ELSIF VMOP = 7 THEN
      (* OP_LOADI_1 (B): R[a] = 1 *)
      VMOPA := VMBC[VMPC];
      VMPC := VMPC + 1;
      VMRV[VMOPA] := 1;
      VMRT[VMOPA] := 4;

    ELSE
      (* 未知のオペコード *)
      VMST := 3;
      VMERR := VMOP;
      EXIT;

    END_IF;

    (* バイトコード範囲チェック *)
    IF VMPC >= VMLEN THEN
      VMST := 2;
      EXIT;
    END_IF;

  END_FOR;
END_IF;
