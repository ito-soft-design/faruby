(* ======================================= *)
(* faRuby VM - Reset Handler *)
(* ======================================= *)
(* 【自動生成】このファイルを直接編集しないでください。 *)
(*   生成: tools/kvs_generator.rb  (rake vm_core) *)
(* *)
(* 毎スキャン実行。RESET_REQ = 1 のインスタンスについて *)
(* VM 状態とレジスタファイルを初期化します。 *)
(* *)
(* **電源投入後の最初のスキャンでも初期化します。** 詳しくは *)
(* emit_restart_on_power_up を見てください。 *)

(* インデックスレジスタの退避 *)
(* Z はラダーと共有する資源のため、faRuby の実行前後で *)
(* 内容が変わらないようにする (1スキャンにつき1回) *)
VMZSAVE[0] := Z1;
VMZSAVE[1] := Z2;
VMZSAVE[2] := Z3;
VMZSAVE[3] := Z4;
VMZSAVE[4] := Z5;
VMZSAVE[5] := Z6;
VMZSAVE[6] := Z7;
VMZSAVE[7] := Z8;
VMZSAVE[8] := Z9;
(* 固定領域 (ZR) のバンクを選ぶ *)
(* 現在のバンクを読む命令が無いため、抜けるときは 0 に戻す *)


(* === 電源投入後の最初のスキャン === *)
(* **実行中のまま切れていたら先頭から走らせ直す。** 継続はしない *)
IF VMFIRSTSCAN THEN
  IF VMSTATUS = 1 THEN
    VMPC := 0;   (* PC = 0 *)
    VMSTATUS := 0;   (* STATUS = stopped *)
    VMERROR := 0;   (* ERROR = none *)
    VMSTEPCOUNTL := 0;   (* STEP_COUNT = 0 *)

    (* 実行中の irep をトップレベル (0番) に戻す *)
    VMFRAMESP := 0;   (* 呼び出しの深さ *)
    VMARRAYSP := 0;   (* 配列プールの空き先頭 *)
    VMREGBASE := 72;   (* レジスタ窓の先頭 *)
    VMCURIREP := 0;
    (* IREP テーブルから実行中の irep の情報を写す *)
    Z1 := VMIREPTABLE;
    VMCURBYTECODE := ZR0Z1;
    VMBYTECODELEN := ZR1Z1;
    VMCURPOOL := ZR2Z1;
    VMCURSYMBOLS := ZR3Z1;
    VMNREGS := ZR4Z1;

    (* レジスタファイルクリア (型タグを TT_EMPTY に) *)
    FOR VMLOOPCOUNTER := 18 TO 97 DO
      VMSLOT[VMLOOPCOUNTER].SLTAG := 0;
    END_FOR;

    (* R[0] はトップレベルの self (main)。**mruby は OP_LOADSELF を書かない** *)
    Z1 := VMREGBASE + 4000;
    VMSLOT[(Z1 - 4000) / 4].SLNUM := 0;
    VMSLOT[(Z1 - 4000) / 4].SLTAG := 10;

    (* 汎用グローバル変数クリア (型タグを TT_EMPTY に) *)
    FOR VMLOOPCOUNTER := 154 TO 253 DO
      VMSLOT[VMLOOPCOUNTER].SLTAG := 0;
    END_FOR;

    VMSTATUS := 1;   (* STATUS = running (先頭から) *)
  END_IF;
  (* 電源が切れる前のリセット要求は意味を失っている。 *)
  (* **残すと走らせ直した直後に止めてしまう** *)
  VMRESETREQ := 0;
END_IF;

IF VMRESETREQ = 1 THEN

  VMPC := 0;   (* PC = 0 *)
  VMSTATUS := 0;   (* STATUS = stopped *)
  VMERROR := 0;   (* ERROR = none *)
  VMSTEPCOUNTL := 0;   (* STEP_COUNT = 0 *)

  (* 実行中の irep をトップレベル (0番) に戻す *)
  VMFRAMESP := 0;   (* 呼び出しの深さ *)
  VMARRAYSP := 0;   (* 配列プールの空き先頭 *)
  VMREGBASE := 72;   (* レジスタ窓の先頭 *)
  VMCURIREP := 0;
  (* IREP テーブルから実行中の irep の情報を写す *)
  Z1 := VMIREPTABLE;
  VMCURBYTECODE := ZR0Z1;
  VMBYTECODELEN := ZR1Z1;
  VMCURPOOL := ZR2Z1;
  VMCURSYMBOLS := ZR3Z1;
  VMNREGS := ZR4Z1;

  (* レジスタファイルクリア (型タグを TT_EMPTY に) *)
  FOR VMLOOPCOUNTER := 18 TO 97 DO
    VMSLOT[VMLOOPCOUNTER].SLTAG := 0;
  END_FOR;

  (* R[0] はトップレベルの self (main)。**mruby は OP_LOADSELF を書かない** *)
  Z1 := VMREGBASE + 4000;
  VMSLOT[(Z1 - 4000) / 4].SLNUM := 0;
  VMSLOT[(Z1 - 4000) / 4].SLTAG := 10;

  (* 汎用グローバル変数クリア (型タグを TT_EMPTY に) *)
  FOR VMLOOPCOUNTER := 154 TO 253 DO
    VMSLOT[VMLOOPCOUNTER].SLTAG := 0;
  END_FOR;

  VMRESETREQ := 0;   (* リセット要求クリア *)

END_IF;


(* ファイルレジスタのバンクを 0 に戻す *)
(* インデックスレジスタの復元 *)
Z1 := VMZSAVE[0];
Z2 := VMZSAVE[1];
Z3 := VMZSAVE[2];
Z4 := VMZSAVE[3];
Z5 := VMZSAVE[4];
Z6 := VMZSAVE[5];
Z7 := VMZSAVE[6];
Z8 := VMZSAVE[7];
Z9 := VMZSAVE[8];