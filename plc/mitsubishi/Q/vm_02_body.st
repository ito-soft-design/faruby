(* ======================================= *)
(* faRuby VM *)
(* ======================================= *)
(* 【自動生成】このファイルを直接編集しないでください。 *)
(*   定義: tools/opcode_table.rb *)
(*   生成: tools/kvs_generator.rb  (rake vm_core) *)
(*   編集した場合 test_kvs_generator.rb が失敗します。 *)
(* *)
(* 【ラダーへの置き方】1 スキャンに 1 回呼ぶだけです *)
(*   vm_01_init.st   リセットハンドラ (本体より先) *)
(*   vm_02_body.st   ← このファイル *)
(* *)
(* **ステップのループはこの中にあります。** ラダーの FOR は回数しか *)
(* 指定できず途中で抜けられませんが、ST の FOR は抜けられます。 *)
(* 命令を打ち切る BREAK もそのままステップのループを抜けます。 *)
(* *)
(* D デバイスを使用。 *)
(* *)
(* インスタンスごとに 2000 ワードのブロックを使います。 *)
(*   インスタンス0  D4000-D5999 *)
(* *)
(* 実行中のブロック先頭は Z9 に載っています。 *)
(* ブロック内の位置はオフセットをインデックス修飾で足して指します。 *)
(* どのインスタンスでも同じコードが動くのはこのためです。 *)
(* *)
(* ブロック先頭からのオフセット: *)
(*   VMPC  = PC (プログラムカウンタ) *)
(*   VMSTATUS  = STATUS (0=停止, 1=実行中, 2=完了, 3=エラー) *)
(*   VMERROR  = ERROR *)
(*   VMSTEPSPERCYCLE  = STEPS_PER_CYCLE *)
(*   VMCURRENTOPCODE  = CURRENT_OPCODE (デバッグ用) *)
(*   VMOPERANDA  = operand a *)
(*   VMOPERANDB  = operand b *)
(*   VMOPERANDC  = operand c *)
(*   VMRESETREQ = RESET_REQ (1=リセット要求, vm_init で処理) *)
(*   VMTEMP32 = 32ビット合成スクラッチ 下位ワード *)
(*   VMTEMP32HI = 32ビット合成スクラッチ 上位ワード *)
(*          D は無サフィックスだと16ビット符号なしのため、負値や *)
(*          65535 超の即値は一旦この2ワードに置いてから .L で読む *)
(*   VMREGBASE = REG_BASE (レジスタ窓の先頭。呼び出しでずれる) *)
(*   VMCURBYTECODE = 実行中の irep のバイトコード先頭 *)
(*   VMCURPOOL = 実行中の irep の定数プール先頭 *)
(*   VMCURSYMBOLS = 実行中の irep のシンボル表先頭 *)
(*   VMARRAYSP = ARRAY_SP (次に渡す配列スロット。返さないので減らない) *)
(*   +56~ = レジスタスタック (値スロット 4ワード/レジスタ) *)
(*   +376~ = 呼び出しスタック (10ワード/段) *)
(*   +536~ = メソッド表 (1ワード/メソッド) *)
(*   +600~ = 汎用グローバル変数 (値スロット 4ワード/変数) *)
(*   +1000~ = 配列プール (50ワード/スロット: 要素数 + 予備 + 要素12個) *)
(* *)
(* 実行中に変わらないものは ZR (ZR をバンク 0 に分けたもの) に置く。 *)
(* **バンクを選ぶ手立てが無く常に 0 です。** ホスト側も同じ バンクへ書くので食い違いません (memory.fixed_bank)。 *)
(* インスタンス0のブロックは ZR0-ZR4999: *)
(*   ZR0~ = IREPテーブル (8ワード/irep) *)
(*   ZR128~ = バイトコード (1バイト/1ワード) *)
(*   ZR3128~ = 定数プール (値スロット 4ワード/エントリ) *)
(*   ZR3728~ = シンボル表 (4ワード/エントリ) *)
(* *)
(* バイトコード・定数プール・シンボル表は全 irep で 1 つの領域を分け合う。 *)
(* irep ごとの位置は IREP テーブルにあり、切り替え時に VM 状態へ写す。 *)
(* そのため上のアドレスは領域の先頭であって、実行中の位置ではない。 *)
(* **インスタンスごとに位置が違うため、EM38:Z9 から引く。** *)
(* *)
(* Z1-Z9 を使用 (Z11/Z12 は特別な用途があり使用不可、Z10 は未使用) *)
(*   Z はラダーと共有する資源のため、スクリプトの先頭で退避し末尾で復元する。 *)
(*   faRuby の実行前後で Z の内容は変わらない。 *)
(*   退避先 D4021-D4029 (インスタンスループの外なので絶対アドレス) *)
(* *)
(* 【重要】インデックス修飾と型サフィックスの順序 *)
(*   正: EM0.L:Z1   デバイスに .L が付く → 32ビットアクセス *)
(*   誤: EM0:Z1.L   .L がインデックスレジスタ Z1 に結合してしまい、 *)
(*                  エラーにならないまま16ビットアクセスになる *)
(*   インデックスの刻み幅は .L でも 1 ワード。下位ワードが先。 *)

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

(* ブロックの先頭を Z9 に載せる *)
Z9 := 4000;

(* 1 スキャンぶんのステップ。**BREAK はこのループを抜ける** *)
FOR VMLOOPCOUNTER := 1 TO VMSTEPSPERCYCLE DO

  (* 止まっていたら残りは回らない *)
  IF VMSTATUS <> 1 THEN
    EXIT;
  END_IF;

  (* === FETCH OPCODE === *)
  VMCURRENTOPCODE := VMCODE[VMPC + VMCURBYTECODE];
  VMPC := VMPC + 1;
  (* レジスタ窓の先頭をスロット単位に直す (添字に使う) *)
  VMREGSLOT := VMREGBASE / 4;
  VMSTEPCOUNTL := VMSTEPCOUNTL + 1;   (* 累計実行命令数 *)

  IF VMCURRENTOPCODE <= 5 THEN
    (* オペコード 0x00 - 0x05 *)
    IF VMCURRENTOPCODE = 0 THEN
      (* OP_NOP (Z): 何もしない *)

      VMDISPATCH := 0;
    ELSIF VMCURRENTOPCODE = 1 THEN
      (* OP_MOVE (BB): R[a] = R[b] *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDB := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDB].SLNUM;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := VMSLOT[VMREGSLOT + VMOPERANDB].SLTAG;

    ELSIF VMCURRENTOPCODE = 2 THEN
      (* OP_LOADL (BB): R[a] = Pool[b] *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDB := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMFSLOT[(VMCURPOOL) / 4 + VMOPERANDB].SLNUM;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := VMFSLOT[(VMCURPOOL) / 4 + VMOPERANDB].SLTAG;

    ELSIF VMCURRENTOPCODE = 3 THEN
      (* OP_LOADI (BB): R[a] = b (符号なし) *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDB := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(VMOPERANDB);
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;

    ELSIF VMCURRENTOPCODE = 4 THEN
      (* OP_LOADINEG (BB): R[a] = -b *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDB := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0 - INT_TO_DINT(VMOPERANDB);
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;

    ELSIF VMCURRENTOPCODE = 5 THEN
      (* OP_LOADI__1 (B): R[a] = -1 *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := -1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;

    ELSE
      (* 未知のオペコード: エラー *)
      VMSTATUS := 3;
      VMERROR := VMCURRENTOPCODE;
      EXIT;

    END_IF;
  ELSIF VMCURRENTOPCODE <= 11 THEN
    (* オペコード 0x06 - 0x0B *)
    IF VMCURRENTOPCODE = 6 THEN
      (* OP_LOADI_0 (B): R[a] = 0 *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;

    ELSIF VMCURRENTOPCODE = 7 THEN
      (* OP_LOADI_1 (B): R[a] = 1 *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;

    ELSIF VMCURRENTOPCODE = 8 THEN
      (* OP_LOADI_2 (B): R[a] = 2 *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 2;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;

    ELSIF VMCURRENTOPCODE = 9 THEN
      (* OP_LOADI_3 (B): R[a] = 3 *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 3;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;

    ELSIF VMCURRENTOPCODE = 10 THEN
      (* OP_LOADI_4 (B): R[a] = 4 *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 4;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;

    ELSIF VMCURRENTOPCODE = 11 THEN
      (* OP_LOADI_5 (B): R[a] = 5 *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 5;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;

    ELSE
      (* 未知のオペコード: エラー *)
      VMSTATUS := 3;
      VMERROR := VMCURRENTOPCODE;
      EXIT;

    END_IF;
  ELSIF VMCURRENTOPCODE <= 18 THEN
    (* オペコード 0x0C - 0x12 *)
    IF VMCURRENTOPCODE = 12 THEN
      (* OP_LOADI_6 (B): R[a] = 6 *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 6;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;

    ELSIF VMCURRENTOPCODE = 13 THEN
      (* OP_LOADI_7 (B): R[a] = 7 *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 7;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;

    ELSIF VMCURRENTOPCODE = 14 THEN
      (* OP_LOADI16 (BS): R[a] = signed16(b) *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      (* 16bit big-endian: hi byte, lo byte *)
      Z3 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      Z4 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDB := Z3 * 256 + Z4;
      (* 16ビット値を符号拡張して32ビットスクラッチに置く *)
      VMTEMP32L := INT_TO_DINT(VMOPERANDB);
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;

    ELSIF VMCURRENTOPCODE = 15 THEN
      (* OP_LOADI32 (BSS): R[a] = (b<<16)+c *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      (* 16bit big-endian: hi byte, lo byte *)
      Z3 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      Z4 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDB := Z3 * 256 + Z4;
      (* 16bit big-endian: hi byte, lo byte *)
      Z3 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      Z4 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDC := Z3 * 256 + Z4;
      (* 上位 * 65536 は16ビット演算になり桁上がりが落ちるため、 *)
      (* 下位/上位ワードを並べて32ビットとして読む *)
      VMTEMP32 := VMOPERANDC;
      VMTEMP32HI := VMOPERANDB;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;

    ELSIF VMCURRENTOPCODE = 17 THEN
      (* OP_LOADNIL (B): R[a] = nil *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 1;

    ELSIF VMCURRENTOPCODE = 18 THEN
      (* OP_LOADSELF (B): R[a] = self (main) *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 10;

    ELSE
      (* 未知のオペコード: エラー *)
      VMSTATUS := 3;
      VMERROR := VMCURRENTOPCODE;
      EXIT;

    END_IF;
  ELSIF VMCURRENTOPCODE <= 36 THEN
    (* オペコード 0x13 - 0x24 *)
    IF VMCURRENTOPCODE = 19 THEN
      (* OP_LOADT (B): R[a] = true *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;

    ELSIF VMCURRENTOPCODE = 20 THEN
      (* OP_LOADF (B): R[a] = false *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
      VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;

    ELSIF VMCURRENTOPCODE = 21 THEN
      (* OP_GETGV (BB): R[a] = global[symbols[b]] *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDB := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      (* シンボル表参照 (4ワード/エントリ) *)
      Z3 := VMOPERANDB * 4 + VMCURSYMBOLS;
      Z4 := Z3 + 1;
      Z5 := ZR0Z3;
      Z6 := ZR0Z4;
      Z7 := Z3 + 2;
      Z8 := ZR0Z7;
      Z7 := Z3 + 3;
      Z1 := ZR0Z7;   (* シンボル種別 *)
      (* レジスタアドレス *)
      (* 種別で 4 つに分ける。いちばん多い普通のデバイスがここで決まる *)
      IF Z1 = 0 THEN
        (* デバイスタイプ別読み取り *)
        (* ワードデバイス (EM, DM, ZF): Z8 (access_type) で幅を選ぶ *)
        (*   2=.L(32bit符号付き) *)
        (*   1=.U(16bit符号なし) *)
        (*   3=.D(32bit符号なし) *)
        (*   4=.F(実数) *)
        (*   それ以外=.S(16bit符号付き/既定) *)
        (* ビットデバイス (M, L, B, X, Y): ON→true, OFF→false *)
        (*   整数の 1/0 ではなく真偽値。0 は Ruby では真なので、 *)
        (*   整数にすると if $MR10 が常に成立してしまう *)
        IF Z5 = 0 THEN
          IF Z8 = 2 THEN
            VMTEMP32 := D0Z6;
            VMTEMP32HI := D1Z6;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          ELSIF Z8 = 1 THEN
            VMTEMP32L := INT_TO_DINT(D0Z6);
            IF VMTEMP32L < 0 THEN
              VMTEMP32L := VMTEMP32L + 65536;
            END_IF;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          ELSIF Z8 = 3 THEN
            VMTEMP32 := D0Z6;
            VMTEMP32HI := D1Z6;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          ELSIF Z8 = 4 THEN
            VMTEMP32 := D0Z6;
            VMTEMP32HI := D1Z6;
            VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(D0Z6);
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          END_IF;
        ELSIF Z5 = 1 THEN
          IF Z8 = 2 THEN
            VMTEMP32 := W0Z6;
            VMTEMP32HI := W1Z6;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          ELSIF Z8 = 1 THEN
            VMTEMP32L := INT_TO_DINT(W0Z6);
            IF VMTEMP32L < 0 THEN
              VMTEMP32L := VMTEMP32L + 65536;
            END_IF;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          ELSIF Z8 = 3 THEN
            VMTEMP32 := W0Z6;
            VMTEMP32HI := W1Z6;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          ELSIF Z8 = 4 THEN
            VMTEMP32 := W0Z6;
            VMTEMP32HI := W1Z6;
            VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(W0Z6);
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          END_IF;
        ELSIF Z5 = 2 THEN
          IF Z8 = 2 THEN
            VMTEMP32 := R0Z6;
            VMTEMP32HI := R1Z6;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          ELSIF Z8 = 1 THEN
            VMTEMP32L := INT_TO_DINT(R0Z6);
            IF VMTEMP32L < 0 THEN
              VMTEMP32L := VMTEMP32L + 65536;
            END_IF;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          ELSIF Z8 = 3 THEN
            VMTEMP32 := R0Z6;
            VMTEMP32HI := R1Z6;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          ELSIF Z8 = 4 THEN
            VMTEMP32 := R0Z6;
            VMTEMP32HI := R1Z6;
            VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(R0Z6);
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          END_IF;
        ELSIF Z5 = 3 THEN
          IF Z8 = 2 THEN
            VMTEMP32 := ZR0Z6;
            VMTEMP32HI := ZR1Z6;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          ELSIF Z8 = 1 THEN
            VMTEMP32L := INT_TO_DINT(ZR0Z6);
            IF VMTEMP32L < 0 THEN
              VMTEMP32L := VMTEMP32L + 65536;
            END_IF;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          ELSIF Z8 = 3 THEN
            VMTEMP32 := ZR0Z6;
            VMTEMP32HI := ZR1Z6;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          ELSIF Z8 = 4 THEN
            VMTEMP32 := ZR0Z6;
            VMTEMP32HI := ZR1Z6;
            VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(ZR0Z6);
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          END_IF;
        ELSIF Z5 = 4 THEN
          IF Z8 = 5 THEN
            IF M0Z6 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8M0Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 1 THEN
              VMTEMP32L := INT_TO_DINT(K4M0Z6);
              IF VMTEMP32L < 0 THEN
                VMTEMP32L := VMTEMP32L + 65536;
              END_IF;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 3 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8M0Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 4 THEN
              VMTEMP32L := K8M0Z6;
              VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(K4M0Z6);
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            END_IF;
          END_IF;
        ELSIF Z5 = 5 THEN
          IF Z8 = 5 THEN
            IF L0Z6 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8L0Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 1 THEN
              VMTEMP32L := INT_TO_DINT(K4L0Z6);
              IF VMTEMP32L < 0 THEN
                VMTEMP32L := VMTEMP32L + 65536;
              END_IF;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 3 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8L0Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 4 THEN
              VMTEMP32L := K8L0Z6;
              VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(K4L0Z6);
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            END_IF;
          END_IF;
        ELSIF Z5 = 6 THEN
          IF Z8 = 5 THEN
            IF B0Z6 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8B0Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 1 THEN
              VMTEMP32L := INT_TO_DINT(K4B0Z6);
              IF VMTEMP32L < 0 THEN
                VMTEMP32L := VMTEMP32L + 65536;
              END_IF;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 3 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8B0Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 4 THEN
              VMTEMP32L := K8B0Z6;
              VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(K4B0Z6);
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            END_IF;
          END_IF;
        ELSIF Z5 = 7 THEN
          IF Z8 = 5 THEN
            IF X0Z6 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8X0Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 1 THEN
              VMTEMP32L := INT_TO_DINT(K4X0Z6);
              IF VMTEMP32L < 0 THEN
                VMTEMP32L := VMTEMP32L + 65536;
              END_IF;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 3 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8X0Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 4 THEN
              VMTEMP32L := K8X0Z6;
              VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(K4X0Z6);
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            END_IF;
          END_IF;
        ELSIF Z5 = 8 THEN
          IF Z8 = 5 THEN
            IF Y0Z6 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8Y0Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 1 THEN
              VMTEMP32L := INT_TO_DINT(K4Y0Z6);
              IF VMTEMP32L < 0 THEN
                VMTEMP32L := VMTEMP32L + 65536;
              END_IF;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 3 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8Y0Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 4 THEN
              VMTEMP32L := K8Y0Z6;
              VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(K4Y0Z6);
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            END_IF;
          END_IF;
        ELSE
          VMSTATUS := 3;
          VMERROR := 21;
          EXIT;
        END_IF;
      ELSIF Z1 = 5 THEN
        (* 汎用グローバルは値スロット。型タグごと写す *)
        Z3 := Z6;
        VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[Z3 / 4].SLNUM;
        VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := VMSLOT[Z3 / 4].SLTAG;
      ELSIF Z1 = 1 THEN
        (* デバイス族。読み書きせず参照値を作る ($DM[i] の $DM の部分) *)
        VMSLOTW[VMREGSLOT + VMOPERANDA].SLW0 := Z6;   (* ベースアドレス *)
        VMSLOTW[VMREGSLOT + VMOPERANDA].SLW1 := Z5 + Z8 * 16;   (* 種別 + 幅 *)
        VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 11;
      ELSE
        (* 文字列を読めるのは D / W / R / ZR だけ *)
        (* **この検査は FOR の外に置く。** 中の BREAK は FOR を抜けるだけで *)
        (* 命令ループから出られず、エラーを書いてもそのまま走り続ける *)
        IF Z5 > 3 THEN
          VMSTATUS := 3;
          VMERROR := 21;
          EXIT;
        END_IF;
        VMSTRTEMP := Z8 / 16;   (* 桁数 = バイト数 *)
        IF VMSTRTEMP = 0 THEN
          (* 桁の無い T は読めない。長さが決まらない *)
          VMSTATUS := 3;
          VMERROR := 21;
          EXIT;
        END_IF;
        IF VMSTRTEMP > 96 THEN
          (* 1 スロットに収まらない桁数 *)
          VMSTATUS := 3;
          VMERROR := 10;
          EXIT;
        END_IF;
        (* プールの空きスロットを取る。返さないので使い切ったら止まる *)
        IF VMARRAYSP >= 16 THEN
          VMSTATUS := 3;
          VMERROR := 10;
          EXIT;
        END_IF;
        Z3 := VMARRAYSP * 50 + 5000;
        D0Z3 := VMSTRTEMP;
        (* ワード単位で写す。並びが同じなので詰め替えは要らない *)
        VMSTRLIMIT := VMSTRTEMP + 1;
        VMSTRLIMIT := VMSTRLIMIT / 2;   (* ワード数 *)
        IF VMSTRLIMIT > 0 THEN
          VMSTRLIMIT := VMSTRLIMIT - 1;
          FOR VMSTRINDEX := 0 TO VMSTRLIMIT DO
            Z4 := VMSTRINDEX + Z6;   (* デバイスの位置 *)
            (* ワードデバイスから 1 ワード。種別は FOR に入る前に検査済み *)
            IF Z5 = 0 THEN
              Z7 := D0Z4;
            ELSIF Z5 = 1 THEN
              Z7 := W0Z4;
            ELSIF Z5 = 2 THEN
              Z7 := R0Z4;
            ELSE
              Z7 := ZR0Z4;
            END_IF;
            Z4 := VMSTRINDEX + Z3 + 2;
            D0Z4 := Z7;
          END_FOR;
        END_IF;
        (* 桁が奇数なら最後のワードの下位バイトは桁の外。0 にして中身に混ぜない *)
        (* 残すと同じ中身どうしの == がワード単位の比較で外れる *)
        VMSTRLIMIT := VMSTRTEMP / 2;
        VMSTRFLAG := VMSTRLIMIT * 2;
        IF VMSTRTEMP <> VMSTRFLAG THEN
          Z4 := VMSTRLIMIT + Z3 + 2;
          Z7 := D0Z4;
          Z7 := Z7 / 256;
          D0Z4 := Z7 * 256;
        END_IF;
        VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(VMARRAYSP);   (* スロット番号 *)
        VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 7;
        VMARRAYSP := VMARRAYSP + 1;
      END_IF;

    ELSIF VMCURRENTOPCODE = 22 THEN
      (* OP_SETGV (BB): global[symbols[b]] = R[a] *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDB := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      (* シンボル表参照 (4ワード/エントリ) *)
      Z3 := VMOPERANDB * 4 + VMCURSYMBOLS;
      Z4 := Z3 + 1;
      Z5 := ZR0Z3;
      Z6 := ZR0Z4;
      Z7 := Z3 + 2;
      Z8 := ZR0Z7;
      Z7 := Z3 + 3;
      Z1 := ZR0Z7;   (* シンボル種別 *)
      (* レジスタアドレス *)
      IF Z1 = 5 THEN
        (* 汎用グローバルは値スロット。型タグごと写す *)
        Z3 := Z6;
        VMSLOT[Z3 / 4].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM;
        VMSLOT[Z3 / 4].SLTAG := VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG;
      ELSIF Z1 = 1 THEN
        (* デバイス族そのものへの代入 ($DM = 1) は意味を持たない *)
        VMSTATUS := 3;
        VMERROR := 22;
        EXIT;
      ELSIF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 7 THEN
        (* 文字列を書けるのは D / W / R / ZR だけ *)
        (* **この検査は FOR の外に置く。** 中の BREAK は FOR を抜けるだけで *)
        (* 命令ループから出られず、エラーを書いてもそのまま走り続ける *)
        IF Z5 > 3 THEN
          VMSTATUS := 3;
          VMERROR := 22;
          EXIT;
        END_IF;
        (* 桁数。0 なら終端付き *)
        Z7 := Z8 / 16;
        (* 文字列スロットの見出し *)
        Z4 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM);
        Z4 := Z4 * 50 + 5000;
        VMTEMP32BL := INT_TO_DINT(D0Z4);   (* バイト数 *)
        (* 書く長さと埋めるバイトを決める *)
        IF Z7 = 0 THEN
          (* 終端付き。バイト列 + 0 *)
          VMTEMP32L := VMTEMP32BL + 1;
          Z8 := 0;
        ELSE
          (* 固定長。余りは FARUBY_STR_FILL *)
          VMTEMP32L := INT_TO_DINT(Z7);
          Z8 := VMSTRFILL;
        END_IF;
        (* 中身の長さ。桁からはみ出す分は切り詰める *)
        IF VMTEMP32BL > VMTEMP32L THEN
          VMTEMP32BL := VMTEMP32L;
        END_IF;
        (* ワード数。奇数バイトなら最後のワードの下位バイトは埋めるバイト *)
        Z2 := DINT_TO_INT(VMTEMP32L) + 1;
        Z2 := Z2 / 2;
        IF Z2 > 0 THEN
          Z2 := Z2 - 1;
          FOR Z3 := 0 TO Z2 DO
            Z1 := Z3 * 2;   (* 先頭バイトの位置 *)
            Z7 := Z1 + 1;
            IF INT_TO_DINT(Z7) < VMTEMP32BL THEN
              (* 2 バイトとも中身。並びが同じなのでそのまま写す *)
              Z7 := Z3 + Z4 + 2;
              Z7 := D0Z7;
            ELSE
              (* 末尾の半端なワード。バイトごとに決める *)
              Z7 := 0;
              IF INT_TO_DINT(Z1) < VMTEMP32BL THEN
                Z7 := Z3 + Z4 + 2;
                Z7 := D0Z7;
                Z7 := Z7 / 256;   (* 上位バイトだけ中身 *)
              ELSE
                IF INT_TO_DINT(Z1) < VMTEMP32L THEN
                  Z7 := Z8;
                END_IF;
              END_IF;
              Z7 := Z7 * 256;
              Z1 := Z1 + 1;
              IF INT_TO_DINT(Z1) < VMTEMP32L THEN
                Z7 := Z7 + Z8;
              END_IF;
            END_IF;
            (* ワードデバイスへ 1 ワード。種別は FOR に入る前に検査済み *)
            Z1 := Z3 + Z6;
            IF Z5 = 0 THEN
              D0Z1 := Z7;
            ELSIF Z5 = 1 THEN
              W0Z1 := Z7;
            ELSIF Z5 = 2 THEN
              R0Z1 := Z7;
            ELSE
              ZR0Z1 := Z7;
            END_IF;
          END_FOR;
        END_IF;
      ELSIF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 8 THEN
        (* **検査はすべて FOR の外に置く。** 中の BREAK は FOR を抜けるだけで *)
        (* 命令ループから出られず、エラーを書いてもそのまま走り続ける *)
        (* 個別ビットには書けない。1 要素が何ビットか決まらない *)
        IF Z8 = 5 THEN
          VMSTATUS := 3;
          VMERROR := 22;
          EXIT;
        END_IF;
        (* 生成コードが知っている種別か。知らない種別は FOR に入る前に弾く *)
        VMSTRCOUNT := 0;
        IF Z5 = 0 THEN
          VMSTRCOUNT := 1;
        END_IF;
        IF Z5 = 1 THEN
          VMSTRCOUNT := 1;
        END_IF;
        IF Z5 = 2 THEN
          VMSTRCOUNT := 1;
        END_IF;
        IF Z5 = 3 THEN
          VMSTRCOUNT := 1;
        END_IF;
        IF Z5 = 4 THEN
          VMSTRCOUNT := 1;
        END_IF;
        IF Z5 = 5 THEN
          VMSTRCOUNT := 1;
        END_IF;
        IF Z5 = 6 THEN
          VMSTRCOUNT := 1;
        END_IF;
        IF Z5 = 7 THEN
          VMSTRCOUNT := 1;
        END_IF;
        IF Z5 = 8 THEN
          VMSTRCOUNT := 1;
        END_IF;
        IF VMSTRCOUNT = 0 THEN
          VMSTATUS := 3;
          VMERROR := 22;
          EXIT;
        END_IF;
        (* 刻み。幅のワード数、ビットデバイスならその 16 倍 *)
        VMSTRLIMIT := 1;
        IF Z8 = 2 THEN
          VMSTRLIMIT := 2;
        END_IF;
        IF Z8 = 3 THEN
          VMSTRLIMIT := 2;
        END_IF;
        IF Z8 = 4 THEN
          VMSTRLIMIT := 2;
        END_IF;
        IF Z5 > 3 THEN
          VMSTRLIMIT := VMSTRLIMIT * 16;
        END_IF;
        (* スロットの見出しと書き先の先頭。どちらもループの中で動かさない *)
        Z4 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM);
        Z4 := Z4 * 50 + 5000;
        VMSTRTEMP := Z6;   (* 書き先の先頭 *)
        VMTEMP32BL := INT_TO_DINT(D0Z4);   (* 要素数 *)
        (* 数値でない要素があった印。FOR を出てから判定する *)
        VMSTRFLAG := 0;
        IF VMTEMP32BL > 0 THEN
          Z7 := DINT_TO_INT(VMTEMP32BL);
          Z7 := Z7 - 1;
          FOR VMSTRINDEX := 0 TO Z7 DO
            Z3 := VMSTRINDEX * 4 + Z4 + 2;
            VMSTRCOUNT := 0;
            IF VMSLOT[Z3 / 4].SLTAG >= 4 THEN
              IF VMSLOT[Z3 / 4].SLTAG <= 5 THEN
                VMSTRCOUNT := 1;
              END_IF;
            END_IF;
            IF VMSTRCOUNT = 0 THEN
              VMSTRFLAG := 1;
            ELSE
              Z6 := VMSTRINDEX * VMSTRLIMIT + VMSTRTEMP;
              (* レジスタの値を書き込み先の幅に合わせて変換する *)
              (* 使う側の形だけを作る。Infinity や NaN の整数変換は *)
              (* 浮動小数点フォーマット異常になるため、.F 書き込みでは行わない *)
              IF Z8 = 4 THEN
                IF VMSLOT[Z3 / 4].SLTAG = 5 THEN
                  VMTEMP32BF := VMSLOTF[Z3 / 4].SLNUM;
                ELSE
                  VMTEMP32BF := DINT_TO_REAL(VMSLOT[Z3 / 4].SLNUM);   (* 整数→実数 *)
                END_IF;
              ELSE
                IF VMSLOT[Z3 / 4].SLTAG = 5 THEN
                  VMTEMP32L := REAL_TO_DINT(VMSLOTF[Z3 / 4].SLNUM);   (* 実数→整数 (0方向へ切り捨て) *)
                  (* この機種の実数→整数は四捨五入。0 方向へ 1 だけ戻す *)
                  IF VMSLOTF[Z3 / 4].SLNUM >= 0.0 THEN
                    IF DINT_TO_REAL(VMTEMP32L) > VMSLOTF[Z3 / 4].SLNUM THEN
                      VMTEMP32L := VMTEMP32L - 1;
                    END_IF;
                  ELSE
                    IF DINT_TO_REAL(VMTEMP32L) < VMSLOTF[Z3 / 4].SLNUM THEN
                      VMTEMP32L := VMTEMP32L + 1;
                    END_IF;
                  END_IF;
                ELSE
                  VMTEMP32L := VMSLOT[Z3 / 4].SLNUM;
                END_IF;
              END_IF;
              (* デバイスタイプ別書き込み *)
              (* ワードデバイス (EM, DM, ZF): Z8 (access_type) で幅を選ぶ *)
              (*   2=.L(32bit符号付き) *)
              (*   1=.U(16bit符号なし) *)
              (*   3=.D(32bit符号なし) *)
              (*   4=.F(実数) *)
              (*   それ以外=.S(16bit符号付き/既定) *)
              (* ビットデバイス (M, L, B, X, Y): 非0→ON, 0→OFF *)
              (*   true=1 / false=nil=0 なので値だけで判定できる *)
              IF Z5 = 0 THEN
                IF Z8 = 2 THEN
                  D0Z6 := VMTEMP32;
                  D1Z6 := VMTEMP32HI;
                ELSIF Z8 = 1 THEN
                  D0Z6 := DINT_TO_INT(VMTEMP32L);
                ELSIF Z8 = 3 THEN
                  D0Z6 := VMTEMP32;
                  D1Z6 := VMTEMP32HI;
                ELSIF Z8 = 4 THEN
                  D0Z6 := VMTEMP32B;
                  D1Z6 := VMTEMP32BHI;
                ELSE
                  D0Z6 := DINT_TO_INT(VMTEMP32L);
                END_IF;
              ELSIF Z5 = 1 THEN
                IF Z8 = 2 THEN
                  W0Z6 := VMTEMP32;
                  W1Z6 := VMTEMP32HI;
                ELSIF Z8 = 1 THEN
                  W0Z6 := DINT_TO_INT(VMTEMP32L);
                ELSIF Z8 = 3 THEN
                  W0Z6 := VMTEMP32;
                  W1Z6 := VMTEMP32HI;
                ELSIF Z8 = 4 THEN
                  W0Z6 := VMTEMP32B;
                  W1Z6 := VMTEMP32BHI;
                ELSE
                  W0Z6 := DINT_TO_INT(VMTEMP32L);
                END_IF;
              ELSIF Z5 = 2 THEN
                IF Z8 = 2 THEN
                  R0Z6 := VMTEMP32;
                  R1Z6 := VMTEMP32HI;
                ELSIF Z8 = 1 THEN
                  R0Z6 := DINT_TO_INT(VMTEMP32L);
                ELSIF Z8 = 3 THEN
                  R0Z6 := VMTEMP32;
                  R1Z6 := VMTEMP32HI;
                ELSIF Z8 = 4 THEN
                  R0Z6 := VMTEMP32B;
                  R1Z6 := VMTEMP32BHI;
                ELSE
                  R0Z6 := DINT_TO_INT(VMTEMP32L);
                END_IF;
              ELSIF Z5 = 3 THEN
                IF Z8 = 2 THEN
                  ZR0Z6 := VMTEMP32;
                  ZR1Z6 := VMTEMP32HI;
                ELSIF Z8 = 1 THEN
                  ZR0Z6 := DINT_TO_INT(VMTEMP32L);
                ELSIF Z8 = 3 THEN
                  ZR0Z6 := VMTEMP32;
                  ZR1Z6 := VMTEMP32HI;
                ELSIF Z8 = 4 THEN
                  ZR0Z6 := VMTEMP32B;
                  ZR1Z6 := VMTEMP32BHI;
                ELSE
                  ZR0Z6 := DINT_TO_INT(VMTEMP32L);
                END_IF;
              ELSIF Z5 = 4 THEN
                IF Z8 = 5 THEN
                  IF VMTEMP32L <> 0 THEN
                    M0Z6 := TRUE;
                  ELSE
                    M0Z6 := FALSE;
                  END_IF;
                ELSE
                  IF Z8 = 2 THEN
                    K8M0Z6 := VMTEMP32L;
                  ELSIF Z8 = 1 THEN
                    K4M0Z6 := DINT_TO_INT(VMTEMP32L);
                  ELSIF Z8 = 3 THEN
                    K8M0Z6 := VMTEMP32L;
                  ELSIF Z8 = 4 THEN
                    K8M0Z6 := VMTEMP32BL;
                  ELSE
                    K4M0Z6 := DINT_TO_INT(VMTEMP32L);
                  END_IF;
                END_IF;
              ELSIF Z5 = 5 THEN
                IF Z8 = 5 THEN
                  IF VMTEMP32L <> 0 THEN
                    L0Z6 := TRUE;
                  ELSE
                    L0Z6 := FALSE;
                  END_IF;
                ELSE
                  IF Z8 = 2 THEN
                    K8L0Z6 := VMTEMP32L;
                  ELSIF Z8 = 1 THEN
                    K4L0Z6 := DINT_TO_INT(VMTEMP32L);
                  ELSIF Z8 = 3 THEN
                    K8L0Z6 := VMTEMP32L;
                  ELSIF Z8 = 4 THEN
                    K8L0Z6 := VMTEMP32BL;
                  ELSE
                    K4L0Z6 := DINT_TO_INT(VMTEMP32L);
                  END_IF;
                END_IF;
              ELSIF Z5 = 6 THEN
                IF Z8 = 5 THEN
                  IF VMTEMP32L <> 0 THEN
                    B0Z6 := TRUE;
                  ELSE
                    B0Z6 := FALSE;
                  END_IF;
                ELSE
                  IF Z8 = 2 THEN
                    K8B0Z6 := VMTEMP32L;
                  ELSIF Z8 = 1 THEN
                    K4B0Z6 := DINT_TO_INT(VMTEMP32L);
                  ELSIF Z8 = 3 THEN
                    K8B0Z6 := VMTEMP32L;
                  ELSIF Z8 = 4 THEN
                    K8B0Z6 := VMTEMP32BL;
                  ELSE
                    K4B0Z6 := DINT_TO_INT(VMTEMP32L);
                  END_IF;
                END_IF;
              ELSIF Z5 = 7 THEN
                IF Z8 = 5 THEN
                  IF VMTEMP32L <> 0 THEN
                    X0Z6 := TRUE;
                  ELSE
                    X0Z6 := FALSE;
                  END_IF;
                ELSE
                  IF Z8 = 2 THEN
                    K8X0Z6 := VMTEMP32L;
                  ELSIF Z8 = 1 THEN
                    K4X0Z6 := DINT_TO_INT(VMTEMP32L);
                  ELSIF Z8 = 3 THEN
                    K8X0Z6 := VMTEMP32L;
                  ELSIF Z8 = 4 THEN
                    K8X0Z6 := VMTEMP32BL;
                  ELSE
                    K4X0Z6 := DINT_TO_INT(VMTEMP32L);
                  END_IF;
                END_IF;
              ELSIF Z5 = 8 THEN
                IF Z8 = 5 THEN
                  IF VMTEMP32L <> 0 THEN
                    Y0Z6 := TRUE;
                  ELSE
                    Y0Z6 := FALSE;
                  END_IF;
                ELSE
                  IF Z8 = 2 THEN
                    K8Y0Z6 := VMTEMP32L;
                  ELSIF Z8 = 1 THEN
                    K4Y0Z6 := DINT_TO_INT(VMTEMP32L);
                  ELSIF Z8 = 3 THEN
                    K8Y0Z6 := VMTEMP32L;
                  ELSIF Z8 = 4 THEN
                    K8Y0Z6 := VMTEMP32BL;
                  ELSE
                    K4Y0Z6 := DINT_TO_INT(VMTEMP32L);
                  END_IF;
                END_IF;
              ELSE
                (* 呼ぶ側が種別を確かめている。ここへは来ない *)
                VMDISPATCH := 0;
              END_IF;
            END_IF;
          END_FOR;
        END_IF;
        IF VMSTRFLAG = 1 THEN
          (* 数値でない要素があった。入れ子の書き出し方は決めていない *)
          VMSTATUS := 3;
          VMERROR := 22;
          EXIT;
        END_IF;
      ELSIF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 9 THEN
        (* ハッシュはデバイスへ写せない。鍵の並べ方が決まらない *)
        VMSTATUS := 3;
        VMERROR := 22;
        EXIT;
      ELSE
        IF Z8 >= 6 THEN
          (* 文字列の桁 (T) に文字列以外を書こうとした *)
          VMSTATUS := 3;
          VMERROR := 22;
          EXIT;
        END_IF;
        (* レジスタの値を書き込み先の幅に合わせて変換する *)
        (* 使う側の形だけを作る。Infinity や NaN の整数変換は *)
        (* 浮動小数点フォーマット異常になるため、.F 書き込みでは行わない *)
        IF Z8 = 4 THEN
          IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 5 THEN
            VMTEMP32BF := VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM;
          ELSE
            VMTEMP32BF := DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM);   (* 整数→実数 *)
          END_IF;
        ELSE
          IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 5 THEN
            VMTEMP32L := REAL_TO_DINT(VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM);   (* 実数→整数 (0方向へ切り捨て) *)
            (* この機種の実数→整数は四捨五入。0 方向へ 1 だけ戻す *)
            IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM >= 0.0 THEN
              IF DINT_TO_REAL(VMTEMP32L) > VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM THEN
                VMTEMP32L := VMTEMP32L - 1;
              END_IF;
            ELSE
              IF DINT_TO_REAL(VMTEMP32L) < VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM THEN
                VMTEMP32L := VMTEMP32L + 1;
              END_IF;
            END_IF;
          ELSE
            VMTEMP32L := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM;
          END_IF;
        END_IF;
        (* デバイスタイプ別書き込み *)
        (* ワードデバイス (EM, DM, ZF): Z8 (access_type) で幅を選ぶ *)
        (*   2=.L(32bit符号付き) *)
        (*   1=.U(16bit符号なし) *)
        (*   3=.D(32bit符号なし) *)
        (*   4=.F(実数) *)
        (*   それ以外=.S(16bit符号付き/既定) *)
        (* ビットデバイス (M, L, B, X, Y): 非0→ON, 0→OFF *)
        (*   true=1 / false=nil=0 なので値だけで判定できる *)
        IF Z5 = 0 THEN
          IF Z8 = 2 THEN
            D0Z6 := VMTEMP32;
            D1Z6 := VMTEMP32HI;
          ELSIF Z8 = 1 THEN
            D0Z6 := DINT_TO_INT(VMTEMP32L);
          ELSIF Z8 = 3 THEN
            D0Z6 := VMTEMP32;
            D1Z6 := VMTEMP32HI;
          ELSIF Z8 = 4 THEN
            D0Z6 := VMTEMP32B;
            D1Z6 := VMTEMP32BHI;
          ELSE
            D0Z6 := DINT_TO_INT(VMTEMP32L);
          END_IF;
        ELSIF Z5 = 1 THEN
          IF Z8 = 2 THEN
            W0Z6 := VMTEMP32;
            W1Z6 := VMTEMP32HI;
          ELSIF Z8 = 1 THEN
            W0Z6 := DINT_TO_INT(VMTEMP32L);
          ELSIF Z8 = 3 THEN
            W0Z6 := VMTEMP32;
            W1Z6 := VMTEMP32HI;
          ELSIF Z8 = 4 THEN
            W0Z6 := VMTEMP32B;
            W1Z6 := VMTEMP32BHI;
          ELSE
            W0Z6 := DINT_TO_INT(VMTEMP32L);
          END_IF;
        ELSIF Z5 = 2 THEN
          IF Z8 = 2 THEN
            R0Z6 := VMTEMP32;
            R1Z6 := VMTEMP32HI;
          ELSIF Z8 = 1 THEN
            R0Z6 := DINT_TO_INT(VMTEMP32L);
          ELSIF Z8 = 3 THEN
            R0Z6 := VMTEMP32;
            R1Z6 := VMTEMP32HI;
          ELSIF Z8 = 4 THEN
            R0Z6 := VMTEMP32B;
            R1Z6 := VMTEMP32BHI;
          ELSE
            R0Z6 := DINT_TO_INT(VMTEMP32L);
          END_IF;
        ELSIF Z5 = 3 THEN
          IF Z8 = 2 THEN
            ZR0Z6 := VMTEMP32;
            ZR1Z6 := VMTEMP32HI;
          ELSIF Z8 = 1 THEN
            ZR0Z6 := DINT_TO_INT(VMTEMP32L);
          ELSIF Z8 = 3 THEN
            ZR0Z6 := VMTEMP32;
            ZR1Z6 := VMTEMP32HI;
          ELSIF Z8 = 4 THEN
            ZR0Z6 := VMTEMP32B;
            ZR1Z6 := VMTEMP32BHI;
          ELSE
            ZR0Z6 := DINT_TO_INT(VMTEMP32L);
          END_IF;
        ELSIF Z5 = 4 THEN
          IF Z8 = 5 THEN
            IF VMTEMP32L <> 0 THEN
              M0Z6 := TRUE;
            ELSE
              M0Z6 := FALSE;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              K8M0Z6 := VMTEMP32L;
            ELSIF Z8 = 1 THEN
              K4M0Z6 := DINT_TO_INT(VMTEMP32L);
            ELSIF Z8 = 3 THEN
              K8M0Z6 := VMTEMP32L;
            ELSIF Z8 = 4 THEN
              K8M0Z6 := VMTEMP32BL;
            ELSE
              K4M0Z6 := DINT_TO_INT(VMTEMP32L);
            END_IF;
          END_IF;
        ELSIF Z5 = 5 THEN
          IF Z8 = 5 THEN
            IF VMTEMP32L <> 0 THEN
              L0Z6 := TRUE;
            ELSE
              L0Z6 := FALSE;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              K8L0Z6 := VMTEMP32L;
            ELSIF Z8 = 1 THEN
              K4L0Z6 := DINT_TO_INT(VMTEMP32L);
            ELSIF Z8 = 3 THEN
              K8L0Z6 := VMTEMP32L;
            ELSIF Z8 = 4 THEN
              K8L0Z6 := VMTEMP32BL;
            ELSE
              K4L0Z6 := DINT_TO_INT(VMTEMP32L);
            END_IF;
          END_IF;
        ELSIF Z5 = 6 THEN
          IF Z8 = 5 THEN
            IF VMTEMP32L <> 0 THEN
              B0Z6 := TRUE;
            ELSE
              B0Z6 := FALSE;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              K8B0Z6 := VMTEMP32L;
            ELSIF Z8 = 1 THEN
              K4B0Z6 := DINT_TO_INT(VMTEMP32L);
            ELSIF Z8 = 3 THEN
              K8B0Z6 := VMTEMP32L;
            ELSIF Z8 = 4 THEN
              K8B0Z6 := VMTEMP32BL;
            ELSE
              K4B0Z6 := DINT_TO_INT(VMTEMP32L);
            END_IF;
          END_IF;
        ELSIF Z5 = 7 THEN
          IF Z8 = 5 THEN
            IF VMTEMP32L <> 0 THEN
              X0Z6 := TRUE;
            ELSE
              X0Z6 := FALSE;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              K8X0Z6 := VMTEMP32L;
            ELSIF Z8 = 1 THEN
              K4X0Z6 := DINT_TO_INT(VMTEMP32L);
            ELSIF Z8 = 3 THEN
              K8X0Z6 := VMTEMP32L;
            ELSIF Z8 = 4 THEN
              K8X0Z6 := VMTEMP32BL;
            ELSE
              K4X0Z6 := DINT_TO_INT(VMTEMP32L);
            END_IF;
          END_IF;
        ELSIF Z5 = 8 THEN
          IF Z8 = 5 THEN
            IF VMTEMP32L <> 0 THEN
              Y0Z6 := TRUE;
            ELSE
              Y0Z6 := FALSE;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              K8Y0Z6 := VMTEMP32L;
            ELSIF Z8 = 1 THEN
              K4Y0Z6 := DINT_TO_INT(VMTEMP32L);
            ELSIF Z8 = 3 THEN
              K8Y0Z6 := VMTEMP32L;
            ELSIF Z8 = 4 THEN
              K8Y0Z6 := VMTEMP32BL;
            ELSE
              K4Y0Z6 := DINT_TO_INT(VMTEMP32L);
            END_IF;
          END_IF;
        ELSE
          VMSTATUS := 3;
          VMERROR := 22;
          EXIT;
        END_IF;
      END_IF;

    ELSIF VMCURRENTOPCODE = 35 THEN
      (* OP_GETIDX (B): R[a] = R[a][R[a+1]] (デバイス・配列・文字列) *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 11 THEN
        (* デバイス参照から種別・幅・アドレスを取り出す *)
        Z8 := VMSLOTW[VMREGSLOT + VMOPERANDA].SLW1 / 16;   (* アクセス幅 *)
        Z5 := VMSLOTW[VMREGSLOT + VMOPERANDA].SLW1 - Z8 * 16;   (* デバイス種別 *)
        (* アドレス = ベース + 添字。範囲外は黙って別の場所を読み書きしてしまうため弾く *)
        VMTEMP32L := INT_TO_DINT(VMSLOTW[VMREGSLOT + VMOPERANDA].SLW0) + VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM;
        IF VMTEMP32L >= 0 THEN
          IF VMTEMP32L <= 65535 THEN
            Z6 := DINT_TO_INT(VMTEMP32L);
          ELSE
            VMSTATUS := 3;
            VMERROR := 2;
            EXIT;
          END_IF;
        ELSE
          VMSTATUS := 3;
          VMERROR := 2;
          EXIT;
        END_IF;
        IF Z8 >= 6 THEN
          (* 文字列を読めるのは D / W / R / ZR だけ *)
          (* **この検査は FOR の外に置く。** 中の BREAK は FOR を抜けるだけで *)
          (* 命令ループから出られず、エラーを書いてもそのまま走り続ける *)
          IF Z5 > 3 THEN
            VMSTATUS := 3;
            VMERROR := 2;
            EXIT;
          END_IF;
          VMSTRTEMP := Z8 / 16;   (* 桁数 = バイト数 *)
          IF VMSTRTEMP = 0 THEN
            (* 桁の無い T は読めない。長さが決まらない *)
            VMSTATUS := 3;
            VMERROR := 2;
            EXIT;
          END_IF;
          IF VMSTRTEMP > 96 THEN
            (* 1 スロットに収まらない桁数 *)
            VMSTATUS := 3;
            VMERROR := 10;
            EXIT;
          END_IF;
          (* プールの空きスロットを取る。返さないので使い切ったら止まる *)
          IF VMARRAYSP >= 16 THEN
            VMSTATUS := 3;
            VMERROR := 10;
            EXIT;
          END_IF;
          Z3 := VMARRAYSP * 50 + 5000;
          D0Z3 := VMSTRTEMP;
          (* ワード単位で写す。並びが同じなので詰め替えは要らない *)
          VMSTRLIMIT := VMSTRTEMP + 1;
          VMSTRLIMIT := VMSTRLIMIT / 2;   (* ワード数 *)
          IF VMSTRLIMIT > 0 THEN
            VMSTRLIMIT := VMSTRLIMIT - 1;
            FOR VMSTRINDEX := 0 TO VMSTRLIMIT DO
              Z4 := VMSTRINDEX + Z6;   (* デバイスの位置 *)
              (* ワードデバイスから 1 ワード。種別は FOR に入る前に検査済み *)
              IF Z5 = 0 THEN
                Z7 := D0Z4;
              ELSIF Z5 = 1 THEN
                Z7 := W0Z4;
              ELSIF Z5 = 2 THEN
                Z7 := R0Z4;
              ELSE
                Z7 := ZR0Z4;
              END_IF;
              Z4 := VMSTRINDEX + Z3 + 2;
              D0Z4 := Z7;
            END_FOR;
          END_IF;
          (* 桁が奇数なら最後のワードの下位バイトは桁の外。0 にして中身に混ぜない *)
          (* 残すと同じ中身どうしの == がワード単位の比較で外れる *)
          VMSTRLIMIT := VMSTRTEMP / 2;
          VMSTRFLAG := VMSTRLIMIT * 2;
          IF VMSTRTEMP <> VMSTRFLAG THEN
            Z4 := VMSTRLIMIT + Z3 + 2;
            Z7 := D0Z4;
            Z7 := Z7 / 256;
            D0Z4 := Z7 * 256;
          END_IF;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(VMARRAYSP);   (* スロット番号 *)
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 7;
          VMARRAYSP := VMARRAYSP + 1;
        ELSE
          (* デバイスタイプ別読み取り *)
          (* ワードデバイス (EM, DM, ZF): Z8 (access_type) で幅を選ぶ *)
          (*   2=.L(32bit符号付き) *)
          (*   1=.U(16bit符号なし) *)
          (*   3=.D(32bit符号なし) *)
          (*   4=.F(実数) *)
          (*   それ以外=.S(16bit符号付き/既定) *)
          (* ビットデバイス (M, L, B, X, Y): ON→true, OFF→false *)
          (*   整数の 1/0 ではなく真偽値。0 は Ruby では真なので、 *)
          (*   整数にすると if $MR10 が常に成立してしまう *)
          IF Z5 = 0 THEN
            IF Z8 = 2 THEN
              VMTEMP32 := D0Z6;
              VMTEMP32HI := D1Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 1 THEN
              VMTEMP32L := INT_TO_DINT(D0Z6);
              IF VMTEMP32L < 0 THEN
                VMTEMP32L := VMTEMP32L + 65536;
              END_IF;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 3 THEN
              VMTEMP32 := D0Z6;
              VMTEMP32HI := D1Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 4 THEN
              VMTEMP32 := D0Z6;
              VMTEMP32HI := D1Z6;
              VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(D0Z6);
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            END_IF;
          ELSIF Z5 = 1 THEN
            IF Z8 = 2 THEN
              VMTEMP32 := W0Z6;
              VMTEMP32HI := W1Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 1 THEN
              VMTEMP32L := INT_TO_DINT(W0Z6);
              IF VMTEMP32L < 0 THEN
                VMTEMP32L := VMTEMP32L + 65536;
              END_IF;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 3 THEN
              VMTEMP32 := W0Z6;
              VMTEMP32HI := W1Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 4 THEN
              VMTEMP32 := W0Z6;
              VMTEMP32HI := W1Z6;
              VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(W0Z6);
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            END_IF;
          ELSIF Z5 = 2 THEN
            IF Z8 = 2 THEN
              VMTEMP32 := R0Z6;
              VMTEMP32HI := R1Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 1 THEN
              VMTEMP32L := INT_TO_DINT(R0Z6);
              IF VMTEMP32L < 0 THEN
                VMTEMP32L := VMTEMP32L + 65536;
              END_IF;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 3 THEN
              VMTEMP32 := R0Z6;
              VMTEMP32HI := R1Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 4 THEN
              VMTEMP32 := R0Z6;
              VMTEMP32HI := R1Z6;
              VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(R0Z6);
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            END_IF;
          ELSIF Z5 = 3 THEN
            IF Z8 = 2 THEN
              VMTEMP32 := ZR0Z6;
              VMTEMP32HI := ZR1Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 1 THEN
              VMTEMP32L := INT_TO_DINT(ZR0Z6);
              IF VMTEMP32L < 0 THEN
                VMTEMP32L := VMTEMP32L + 65536;
              END_IF;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 3 THEN
              VMTEMP32 := ZR0Z6;
              VMTEMP32HI := ZR1Z6;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            ELSIF Z8 = 4 THEN
              VMTEMP32 := ZR0Z6;
              VMTEMP32HI := ZR1Z6;
              VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(ZR0Z6);
              VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
            END_IF;
          ELSIF Z5 = 4 THEN
            IF Z8 = 5 THEN
              IF M0Z6 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
              ELSE
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
              END_IF;
            ELSE
              IF Z8 = 2 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8M0Z6;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 1 THEN
                VMTEMP32L := INT_TO_DINT(K4M0Z6);
                IF VMTEMP32L < 0 THEN
                  VMTEMP32L := VMTEMP32L + 65536;
                END_IF;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 3 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8M0Z6;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 4 THEN
                VMTEMP32L := K8M0Z6;
                VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
              ELSE
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(K4M0Z6);
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              END_IF;
            END_IF;
          ELSIF Z5 = 5 THEN
            IF Z8 = 5 THEN
              IF L0Z6 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
              ELSE
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
              END_IF;
            ELSE
              IF Z8 = 2 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8L0Z6;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 1 THEN
                VMTEMP32L := INT_TO_DINT(K4L0Z6);
                IF VMTEMP32L < 0 THEN
                  VMTEMP32L := VMTEMP32L + 65536;
                END_IF;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 3 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8L0Z6;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 4 THEN
                VMTEMP32L := K8L0Z6;
                VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
              ELSE
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(K4L0Z6);
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              END_IF;
            END_IF;
          ELSIF Z5 = 6 THEN
            IF Z8 = 5 THEN
              IF B0Z6 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
              ELSE
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
              END_IF;
            ELSE
              IF Z8 = 2 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8B0Z6;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 1 THEN
                VMTEMP32L := INT_TO_DINT(K4B0Z6);
                IF VMTEMP32L < 0 THEN
                  VMTEMP32L := VMTEMP32L + 65536;
                END_IF;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 3 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8B0Z6;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 4 THEN
                VMTEMP32L := K8B0Z6;
                VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
              ELSE
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(K4B0Z6);
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              END_IF;
            END_IF;
          ELSIF Z5 = 7 THEN
            IF Z8 = 5 THEN
              IF X0Z6 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
              ELSE
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
              END_IF;
            ELSE
              IF Z8 = 2 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8X0Z6;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 1 THEN
                VMTEMP32L := INT_TO_DINT(K4X0Z6);
                IF VMTEMP32L < 0 THEN
                  VMTEMP32L := VMTEMP32L + 65536;
                END_IF;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 3 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8X0Z6;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 4 THEN
                VMTEMP32L := K8X0Z6;
                VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
              ELSE
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(K4X0Z6);
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              END_IF;
            END_IF;
          ELSIF Z5 = 8 THEN
            IF Z8 = 5 THEN
              IF Y0Z6 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
              ELSE
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
              END_IF;
            ELSE
              IF Z8 = 2 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8Y0Z6;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 1 THEN
                VMTEMP32L := INT_TO_DINT(K4Y0Z6);
                IF VMTEMP32L < 0 THEN
                  VMTEMP32L := VMTEMP32L + 65536;
                END_IF;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32L;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 3 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := K8Y0Z6;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              ELSIF Z8 = 4 THEN
                VMTEMP32L := K8Y0Z6;
                VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMTEMP32F;
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
              ELSE
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(K4Y0Z6);
                VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
              END_IF;
            END_IF;
          ELSE
            VMSTATUS := 3;
            VMERROR := 2;
            EXIT;
          END_IF;
        END_IF;
      ELSIF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 8 THEN
        (* スロットの見出し。R[a] を書き換える前に読む *)
        Z4 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM);
        Z4 := Z4 * 50 + 5000;
        VMTEMP32BL := INT_TO_DINT(D0Z4);   (* 要素数 *)
        (* 負の添字は後ろから数える (Ruby の a[-1] は最後の要素) *)
        VMTEMP32L := VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM;
        IF VMTEMP32L < 0 THEN
          VMTEMP32L := VMTEMP32L + VMTEMP32BL;
        END_IF;
        (* 範囲外は nil (Ruby と同じ)。エラーにはしない *)
        IF VMTEMP32L < 0 THEN
          VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 1;
        ELSIF VMTEMP32L >= VMTEMP32BL THEN
          VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 1;
        ELSE
          Z5 := DINT_TO_INT(VMTEMP32L);
          Z5 := Z5 * 4 + Z4 + 2;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[Z5 / 4].SLNUM;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := VMSLOT[Z5 / 4].SLTAG;
        END_IF;
      ELSIF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 9 THEN
        (* 鍵の配列の見出し。R[a] を書き換える前に読む *)
        Z4 := VMSLOTW[VMREGSLOT + VMOPERANDA].SLW0;
        Z4 := Z4 * 50 + 5000;
        VMTEMP32BL := INT_TO_DINT(D0Z4);   (* 組の数 *)
        Z5 := VMSLOTW[VMREGSLOT + VMOPERANDA].SLW1;   (* 値の配列 *)
        Z5 := Z5 * 50 + 5000;
        (* 鍵を先頭から探す。一致は型と値の両方 (Ruby の eql? と同じ) *)
        VMTEMP32L := -1;
        IF VMTEMP32BL > 0 THEN
          Z8 := DINT_TO_INT(VMTEMP32BL);
          Z8 := Z8 - 1;
          FOR Z6 := 0 TO Z8 DO
            IF VMTEMP32L < 0 THEN
              (* 最初に一致したものを採る *)
              Z7 := Z6 * 4 + Z4 + 2;
              IF VMSLOT[Z7 / 4].SLTAG = VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG THEN
                IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 7 THEN
                  (* 文字列の鍵は中身で照合する。スロットが違っても同じ鍵 *)
                  (* 文字列は中身で比べる。スロット番号ではない *)
                  (* Z3 を借りる。返すまでの間に呼ぶ側の値を壊さないため *)
                  VMSTRSAVEDZ := Z3;
                  VMSTRFLAG := 0;
                  Z3 := DINT_TO_INT(VMSLOT[Z7 / 4].SLNUM);
                  Z3 := Z3 * 50 + 5000;
                  VMSTRTEMP := D0Z3;   (* バイト数 *)
                  Z3 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM);
                  Z3 := Z3 * 50 + 5000;
                  IF VMSTRTEMP = D0Z3 THEN
                    (* バイト数が同じ。ここから中身を見る *)
                    VMSTRFLAG := 1;
                    VMSTRLIMIT := VMSTRTEMP + 1;
                    VMSTRLIMIT := VMSTRLIMIT / 2;   (* ワード数 *)
                    IF VMSTRLIMIT > 0 THEN
                      VMSTRLIMIT := VMSTRLIMIT - 1;
                      FOR VMSTRINDEX := 0 TO VMSTRLIMIT DO
                        Z3 := DINT_TO_INT(VMSLOT[Z7 / 4].SLNUM);
                        Z3 := Z3 * 50 + 5000;
                        Z3 := VMSTRINDEX + Z3 + 2;
                        VMSTRTEMP := D0Z3;
                        Z3 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM);
                        Z3 := Z3 * 50 + 5000;
                        Z3 := VMSTRINDEX + Z3 + 2;
                        IF VMSTRTEMP <> D0Z3 THEN
                          VMSTRFLAG := 0;
                        END_IF;
                      END_FOR;
                    END_IF;
                  END_IF;
                  (* 借りた Z3 を返す *)
                  Z3 := VMSTRSAVEDZ;
                  IF VMSTRFLAG = 1 THEN
                    VMTEMP32L := INT_TO_DINT(Z6);
                  END_IF;
                ELSE
                  IF VMSLOT[Z7 / 4].SLNUM = VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
                    VMTEMP32L := INT_TO_DINT(Z6);
                  END_IF;
                END_IF;
              END_IF;
            END_IF;
          END_FOR;
        END_IF;
        IF VMTEMP32L < 0 THEN
          (* 無い鍵は nil (Ruby と同じ) *)
          VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 1;
        ELSE
          Z7 := DINT_TO_INT(VMTEMP32L);
          Z7 := Z7 * 4 + Z5 + 2;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[Z7 / 4].SLNUM;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := VMSLOT[Z7 / 4].SLTAG;
        END_IF;
      ELSIF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 7 THEN
        Z4 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM);
        Z4 := Z4 * 50 + 5000;
        VMTEMP32L := VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM;
        IF VMTEMP32L < 0 THEN
          (* 負の添字は後ろから数える。文字数が要るので一度なめる *)
          VMSTRTARGET := 32767;
          (* 文字の切れ目を先頭から数える。バイト列は 1 回だけなめる *)
          VMSTRLIMIT := D0Z4;   (* バイト数 *)
          VMSTRCOUNT := 0;
          VMSTRSKIP := 0;
          VMSTRFOUND := VMSTRLIMIT;   (* 見つからなければバイト数のまま *)
          VMSTRFOUNDEND := VMSTRLIMIT;
          IF VMSTRLIMIT > 0 THEN
            Z6 := VMSTRLIMIT;
            Z6 := Z6 - 1;
            FOR VMSTRINDEX := 0 TO Z6 DO
              Z8 := VMSTRINDEX / 2;
              Z7 := Z8 + Z4 + 2;
              Z7 := D0Z7;
              Z8 := Z8 * 2;
              IF VMSTRINDEX = Z8 THEN
                Z7 := Z7 / 256;   (* 偶数の位置は上位バイト *)
              ELSE
                Z8 := Z7 / 256;
                Z7 := Z7 - Z8 * 256;   (* 奇数の位置は下位バイト *)
              END_IF;
              (* この位置が文字の先頭かどうか *)
              VMSTRFLAG := 1;
              IF VMSTRENCODING = 0 THEN
                (* 継続バイト (10xxxxxx) は文字の途中 *)
                IF Z7 >= 128 THEN
                  IF Z7 < 192 THEN
                    VMSTRFLAG := 0;
                  END_IF;
                END_IF;
              ELSIF VMSTRENCODING = 1 THEN
                IF VMSTRSKIP = 1 THEN
                  (* 先導バイトの次は後続バイト *)
                  VMSTRFLAG := 0;
                  VMSTRSKIP := 0;
                ELSE
                  (* 先導バイト (0x81-0x9F, 0xE0-0xEF) なら次のバイトは後続 *)
                  IF Z7 >= 129 THEN
                    IF Z7 <= 159 THEN
                      VMSTRSKIP := 1;
                    END_IF;
                  END_IF;
                  IF Z7 >= 224 THEN
                    IF Z7 <= 239 THEN
                      VMSTRSKIP := 1;
                    END_IF;
                  END_IF;
                END_IF;
              END_IF;
              (* ASCII はどのバイトも文字の先頭なので何も見ない *)
              IF VMSTRFLAG = 1 THEN
                IF VMSTRTARGET <= 96 THEN
                  (* 探している文字なら位置を控える。次の切れ目がその文字の終わり *)
                  IF VMSTRCOUNT = VMSTRTARGET THEN
                    VMSTRFOUND := VMSTRINDEX;
                  END_IF;
                  Z7 := VMSTRTARGET + 1;
                  IF VMSTRCOUNT = Z7 THEN
                    VMSTRFOUNDEND := VMSTRINDEX;
                  END_IF;
                END_IF;
                VMSTRCOUNT := VMSTRCOUNT + 1;
              END_IF;
            END_FOR;
          END_IF;
          VMTEMP32L := VMTEMP32L + INT_TO_DINT(VMSTRCOUNT);
        END_IF;
        IF VMTEMP32L < 0 THEN
          (* 後ろから数えても先頭より前。範囲外は nil (Ruby と同じ) *)
          VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 1;
        ELSIF VMTEMP32L > 96 THEN
          (* 1 文字 1 バイト以上なので、バイト数を超える番号は必ず範囲外 *)
          VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 1;
        ELSE
          VMSTRTARGET := DINT_TO_INT(VMTEMP32L);
          (* 文字の切れ目を先頭から数える。バイト列は 1 回だけなめる *)
          VMSTRLIMIT := D0Z4;   (* バイト数 *)
          VMSTRCOUNT := 0;
          VMSTRSKIP := 0;
          VMSTRFOUND := VMSTRLIMIT;   (* 見つからなければバイト数のまま *)
          VMSTRFOUNDEND := VMSTRLIMIT;
          IF VMSTRLIMIT > 0 THEN
            Z6 := VMSTRLIMIT;
            Z6 := Z6 - 1;
            FOR VMSTRINDEX := 0 TO Z6 DO
              Z8 := VMSTRINDEX / 2;
              Z7 := Z8 + Z4 + 2;
              Z7 := D0Z7;
              Z8 := Z8 * 2;
              IF VMSTRINDEX = Z8 THEN
                Z7 := Z7 / 256;   (* 偶数の位置は上位バイト *)
              ELSE
                Z8 := Z7 / 256;
                Z7 := Z7 - Z8 * 256;   (* 奇数の位置は下位バイト *)
              END_IF;
              (* この位置が文字の先頭かどうか *)
              VMSTRFLAG := 1;
              IF VMSTRENCODING = 0 THEN
                (* 継続バイト (10xxxxxx) は文字の途中 *)
                IF Z7 >= 128 THEN
                  IF Z7 < 192 THEN
                    VMSTRFLAG := 0;
                  END_IF;
                END_IF;
              ELSIF VMSTRENCODING = 1 THEN
                IF VMSTRSKIP = 1 THEN
                  (* 先導バイトの次は後続バイト *)
                  VMSTRFLAG := 0;
                  VMSTRSKIP := 0;
                ELSE
                  (* 先導バイト (0x81-0x9F, 0xE0-0xEF) なら次のバイトは後続 *)
                  IF Z7 >= 129 THEN
                    IF Z7 <= 159 THEN
                      VMSTRSKIP := 1;
                    END_IF;
                  END_IF;
                  IF Z7 >= 224 THEN
                    IF Z7 <= 239 THEN
                      VMSTRSKIP := 1;
                    END_IF;
                  END_IF;
                END_IF;
              END_IF;
              (* ASCII はどのバイトも文字の先頭なので何も見ない *)
              IF VMSTRFLAG = 1 THEN
                IF VMSTRTARGET <= 96 THEN
                  (* 探している文字なら位置を控える。次の切れ目がその文字の終わり *)
                  IF VMSTRCOUNT = VMSTRTARGET THEN
                    VMSTRFOUND := VMSTRINDEX;
                  END_IF;
                  Z7 := VMSTRTARGET + 1;
                  IF VMSTRCOUNT = Z7 THEN
                    VMSTRFOUNDEND := VMSTRINDEX;
                  END_IF;
                END_IF;
                VMSTRCOUNT := VMSTRCOUNT + 1;
              END_IF;
            END_FOR;
          END_IF;
          IF VMSTRFOUND >= VMSTRLIMIT THEN
            (* そこまで文字が無い。範囲外は nil (Ruby と同じ) *)
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 1;
          ELSE
            (* プールの空きスロットを取る。返さないので使い切ったら止まる *)
            IF VMARRAYSP >= 16 THEN
              VMSTATUS := 3;
              VMERROR := 10;
              EXIT;
            END_IF;
            Z3 := VMARRAYSP;
            Z3 := Z3 * 50 + 5000;
            VMTEMP32L := 0;   (* 新しいスロットは空から始める *)
            VMTEMP32BL := INT_TO_DINT(VMSTRFOUNDEND) - INT_TO_DINT(VMSTRFOUND);   (* その文字のバイト数 *)
            IF VMTEMP32BL > 0 THEN
              Z6 := DINT_TO_INT(VMTEMP32BL);
              Z6 := Z6 - 1;
              FOR Z5 := 0 TO Z6 DO
                (* 継ぎ足す元のバイトを 1 つ取り出す *)
                VMSTRSKIP := VMSTRFOUND + Z5;   (* 元の位置 *)
                Z7 := VMSTRSKIP / 2;
                Z8 := Z7 + Z4 + 2;
                Z8 := D0Z8;
                Z7 := Z7 * 2;
                IF VMSTRSKIP = Z7 THEN
                  Z8 := Z8 / 256;   (* 偶数の位置は上位バイト *)
                ELSE
                  Z7 := Z8 / 256;
                  Z8 := Z8 - Z7 * 256;   (* 奇数の位置は下位バイト *)
                END_IF;
                (* 書き先の位置 (継ぎ足す先の長さ + 何バイト目か) *)
                VMSTRTEMP := DINT_TO_INT(VMTEMP32L) + Z5;
                Z7 := VMSTRTEMP;
                Z7 := Z7 / 2;
                Z7 := Z7 + Z3 + 2;
                VMSTRLIMIT := VMSTRTEMP / 2;
                VMSTRLIMIT := VMSTRLIMIT * 2;
                IF VMSTRTEMP = VMSTRLIMIT THEN
                  (* 偶数。下位バイトは 0 にしておく (次のバイトか詰め物が入る) *)
                  D0Z7 := Z8 * 256;
                ELSE
                  (* 奇数。上位バイトを残して下位に入れる *)
                  VMSTRLIMIT := D0Z7;
                  VMSTRLIMIT := VMSTRLIMIT / 256;
                  D0Z7 := VMSTRLIMIT * 256 + Z8;
                END_IF;
              END_FOR;
            END_IF;
            (* 長さを更新する *)
            VMTEMP32L := VMTEMP32L + VMTEMP32BL;
            D0Z3 := DINT_TO_INT(VMTEMP32L);
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(VMARRAYSP);   (* スロット番号 *)
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 7;
            VMARRAYSP := VMARRAYSP + 1;
          END_IF;
        END_IF;
      ELSIF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 4 THEN
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG <> 4 THEN
          VMSTATUS := 3;
          VMERROR := 2;
          EXIT;
        END_IF;
        (* 整数のビットを 1 つ取る (Ruby の Integer#[]) *)
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM < 0 THEN
          (* 添字が負なら 0 (Ruby と同じ) *)
          VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
        ELSE
          VMTEMP32BL := VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM;   (* 桁数 *)
          IF VMTEMP32BL >= 32 THEN
            (* 全部ずれる。左は 0、右は符号で埋まる *)
            IF VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM < 0 THEN
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := -1;
            ELSE
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            END_IF;
          ELSE
            IF VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM < 0 THEN
              (* 負は反転して正にしてからずらし、戻す。符号が保たれる *)
              VMTEMP32L := -(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM);
              VMTEMP32L := VMTEMP32L - 1;   (* ~x = -x - 1 *)
              IF VMTEMP32BL >= 16 THEN
                VMTEMP32L := VMTEMP32L / 65536;
                VMTEMP32BL := VMTEMP32BL - 16;
              END_IF;
              IF VMTEMP32BL >= 8 THEN
                VMTEMP32L := VMTEMP32L / 256;
                VMTEMP32BL := VMTEMP32BL - 8;
              END_IF;
              IF VMTEMP32BL >= 4 THEN
                VMTEMP32L := VMTEMP32L / 16;
                VMTEMP32BL := VMTEMP32BL - 4;
              END_IF;
              IF VMTEMP32BL >= 2 THEN
                VMTEMP32L := VMTEMP32L / 4;
                VMTEMP32BL := VMTEMP32BL - 2;
              END_IF;
              IF VMTEMP32BL >= 1 THEN
                VMTEMP32L := VMTEMP32L / 2;
              END_IF;
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := -(VMTEMP32L);
              VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM - 1;   (* ~x = -x - 1 *)
            ELSE
              IF VMTEMP32BL >= 16 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM / 65536;
                VMTEMP32BL := VMTEMP32BL - 16;
              END_IF;
              IF VMTEMP32BL >= 8 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM / 256;
                VMTEMP32BL := VMTEMP32BL - 8;
              END_IF;
              IF VMTEMP32BL >= 4 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM / 16;
                VMTEMP32BL := VMTEMP32BL - 4;
              END_IF;
              IF VMTEMP32BL >= 2 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM / 4;
                VMTEMP32BL := VMTEMP32BL - 2;
              END_IF;
              IF VMTEMP32BL >= 1 THEN
                VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM / 2;
              END_IF;
            END_IF;
          END_IF;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := DWORD_TO_DINT(DINT_TO_DWORD(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM) AND DINT_TO_DWORD(1));
        END_IF;
      ELSE
        (* デバイス参照・配列・ハッシュ・文字列・整数以外への添字アクセスは未対応 *)
        VMSTATUS := 3;
        VMERROR := 2;
        EXIT;
      END_IF;

    ELSIF VMCURRENTOPCODE = 36 THEN
      (* OP_SETIDX (B): R[a][R[a+1]] = R[a+2] (デバイス・配列) *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 11 THEN
        (* デバイス参照から種別・幅・アドレスを取り出す *)
        Z8 := VMSLOTW[VMREGSLOT + VMOPERANDA].SLW1 / 16;   (* アクセス幅 *)
        Z5 := VMSLOTW[VMREGSLOT + VMOPERANDA].SLW1 - Z8 * 16;   (* デバイス種別 *)
        (* アドレス = ベース + 添字。範囲外は黙って別の場所を読み書きしてしまうため弾く *)
        VMTEMP32L := INT_TO_DINT(VMSLOTW[VMREGSLOT + VMOPERANDA].SLW0) + VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM;
        IF VMTEMP32L >= 0 THEN
          IF VMTEMP32L <= 65535 THEN
            Z6 := DINT_TO_INT(VMTEMP32L);
          ELSE
            VMSTATUS := 3;
            VMERROR := 2;
            EXIT;
          END_IF;
        ELSE
          VMSTATUS := 3;
          VMERROR := 2;
          EXIT;
        END_IF;
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLTAG = 7 THEN
          (* 文字列を書けるのは D / W / R / ZR だけ *)
          (* **この検査は FOR の外に置く。** 中の BREAK は FOR を抜けるだけで *)
          (* 命令ループから出られず、エラーを書いてもそのまま走り続ける *)
          IF Z5 > 3 THEN
            VMSTATUS := 3;
            VMERROR := 2;
            EXIT;
          END_IF;
          (* 桁数。0 なら終端付き *)
          Z7 := Z8 / 16;
          (* 文字列スロットの見出し *)
          Z4 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLNUM);
          Z4 := Z4 * 50 + 5000;
          VMTEMP32BL := INT_TO_DINT(D0Z4);   (* バイト数 *)
          (* 書く長さと埋めるバイトを決める *)
          IF Z7 = 0 THEN
            (* 終端付き。バイト列 + 0 *)
            VMTEMP32L := VMTEMP32BL + 1;
            Z8 := 0;
          ELSE
            (* 固定長。余りは FARUBY_STR_FILL *)
            VMTEMP32L := INT_TO_DINT(Z7);
            Z8 := VMSTRFILL;
          END_IF;
          (* 中身の長さ。桁からはみ出す分は切り詰める *)
          IF VMTEMP32BL > VMTEMP32L THEN
            VMTEMP32BL := VMTEMP32L;
          END_IF;
          (* ワード数。奇数バイトなら最後のワードの下位バイトは埋めるバイト *)
          Z2 := DINT_TO_INT(VMTEMP32L) + 1;
          Z2 := Z2 / 2;
          IF Z2 > 0 THEN
            Z2 := Z2 - 1;
            FOR Z3 := 0 TO Z2 DO
              Z1 := Z3 * 2;   (* 先頭バイトの位置 *)
              Z7 := Z1 + 1;
              IF INT_TO_DINT(Z7) < VMTEMP32BL THEN
                (* 2 バイトとも中身。並びが同じなのでそのまま写す *)
                Z7 := Z3 + Z4 + 2;
                Z7 := D0Z7;
              ELSE
                (* 末尾の半端なワード。バイトごとに決める *)
                Z7 := 0;
                IF INT_TO_DINT(Z1) < VMTEMP32BL THEN
                  Z7 := Z3 + Z4 + 2;
                  Z7 := D0Z7;
                  Z7 := Z7 / 256;   (* 上位バイトだけ中身 *)
                ELSE
                  IF INT_TO_DINT(Z1) < VMTEMP32L THEN
                    Z7 := Z8;
                  END_IF;
                END_IF;
                Z7 := Z7 * 256;
                Z1 := Z1 + 1;
                IF INT_TO_DINT(Z1) < VMTEMP32L THEN
                  Z7 := Z7 + Z8;
                END_IF;
              END_IF;
              (* ワードデバイスへ 1 ワード。種別は FOR に入る前に検査済み *)
              Z1 := Z3 + Z6;
              IF Z5 = 0 THEN
                D0Z1 := Z7;
              ELSIF Z5 = 1 THEN
                W0Z1 := Z7;
              ELSIF Z5 = 2 THEN
                R0Z1 := Z7;
              ELSE
                ZR0Z1 := Z7;
              END_IF;
            END_FOR;
          END_IF;
        ELSIF VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLTAG = 8 THEN
          (* **検査はすべて FOR の外に置く。** 中の BREAK は FOR を抜けるだけで *)
          (* 命令ループから出られず、エラーを書いてもそのまま走り続ける *)
          (* 個別ビットには書けない。1 要素が何ビットか決まらない *)
          IF Z8 = 5 THEN
            VMSTATUS := 3;
            VMERROR := 2;
            EXIT;
          END_IF;
          (* 生成コードが知っている種別か。知らない種別は FOR に入る前に弾く *)
          VMSTRCOUNT := 0;
          IF Z5 = 0 THEN
            VMSTRCOUNT := 1;
          END_IF;
          IF Z5 = 1 THEN
            VMSTRCOUNT := 1;
          END_IF;
          IF Z5 = 2 THEN
            VMSTRCOUNT := 1;
          END_IF;
          IF Z5 = 3 THEN
            VMSTRCOUNT := 1;
          END_IF;
          IF Z5 = 4 THEN
            VMSTRCOUNT := 1;
          END_IF;
          IF Z5 = 5 THEN
            VMSTRCOUNT := 1;
          END_IF;
          IF Z5 = 6 THEN
            VMSTRCOUNT := 1;
          END_IF;
          IF Z5 = 7 THEN
            VMSTRCOUNT := 1;
          END_IF;
          IF Z5 = 8 THEN
            VMSTRCOUNT := 1;
          END_IF;
          IF VMSTRCOUNT = 0 THEN
            VMSTATUS := 3;
            VMERROR := 2;
            EXIT;
          END_IF;
          (* 刻み。幅のワード数、ビットデバイスならその 16 倍 *)
          VMSTRLIMIT := 1;
          IF Z8 = 2 THEN
            VMSTRLIMIT := 2;
          END_IF;
          IF Z8 = 3 THEN
            VMSTRLIMIT := 2;
          END_IF;
          IF Z8 = 4 THEN
            VMSTRLIMIT := 2;
          END_IF;
          IF Z5 > 3 THEN
            VMSTRLIMIT := VMSTRLIMIT * 16;
          END_IF;
          (* スロットの見出しと書き先の先頭。どちらもループの中で動かさない *)
          Z4 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLNUM);
          Z4 := Z4 * 50 + 5000;
          VMSTRTEMP := Z6;   (* 書き先の先頭 *)
          VMTEMP32BL := INT_TO_DINT(D0Z4);   (* 要素数 *)
          (* 数値でない要素があった印。FOR を出てから判定する *)
          VMSTRFLAG := 0;
          IF VMTEMP32BL > 0 THEN
            Z7 := DINT_TO_INT(VMTEMP32BL);
            Z7 := Z7 - 1;
            FOR VMSTRINDEX := 0 TO Z7 DO
              Z3 := VMSTRINDEX * 4 + Z4 + 2;
              VMSTRCOUNT := 0;
              IF VMSLOT[Z3 / 4].SLTAG >= 4 THEN
                IF VMSLOT[Z3 / 4].SLTAG <= 5 THEN
                  VMSTRCOUNT := 1;
                END_IF;
              END_IF;
              IF VMSTRCOUNT = 0 THEN
                VMSTRFLAG := 1;
              ELSE
                Z6 := VMSTRINDEX * VMSTRLIMIT + VMSTRTEMP;
                (* レジスタの値を書き込み先の幅に合わせて変換する *)
                (* 使う側の形だけを作る。Infinity や NaN の整数変換は *)
                (* 浮動小数点フォーマット異常になるため、.F 書き込みでは行わない *)
                IF Z8 = 4 THEN
                  IF VMSLOT[Z3 / 4].SLTAG = 5 THEN
                    VMTEMP32BF := VMSLOTF[Z3 / 4].SLNUM;
                  ELSE
                    VMTEMP32BF := DINT_TO_REAL(VMSLOT[Z3 / 4].SLNUM);   (* 整数→実数 *)
                  END_IF;
                ELSE
                  IF VMSLOT[Z3 / 4].SLTAG = 5 THEN
                    VMTEMP32L := REAL_TO_DINT(VMSLOTF[Z3 / 4].SLNUM);   (* 実数→整数 (0方向へ切り捨て) *)
                    (* この機種の実数→整数は四捨五入。0 方向へ 1 だけ戻す *)
                    IF VMSLOTF[Z3 / 4].SLNUM >= 0.0 THEN
                      IF DINT_TO_REAL(VMTEMP32L) > VMSLOTF[Z3 / 4].SLNUM THEN
                        VMTEMP32L := VMTEMP32L - 1;
                      END_IF;
                    ELSE
                      IF DINT_TO_REAL(VMTEMP32L) < VMSLOTF[Z3 / 4].SLNUM THEN
                        VMTEMP32L := VMTEMP32L + 1;
                      END_IF;
                    END_IF;
                  ELSE
                    VMTEMP32L := VMSLOT[Z3 / 4].SLNUM;
                  END_IF;
                END_IF;
                (* デバイスタイプ別書き込み *)
                (* ワードデバイス (EM, DM, ZF): Z8 (access_type) で幅を選ぶ *)
                (*   2=.L(32bit符号付き) *)
                (*   1=.U(16bit符号なし) *)
                (*   3=.D(32bit符号なし) *)
                (*   4=.F(実数) *)
                (*   それ以外=.S(16bit符号付き/既定) *)
                (* ビットデバイス (M, L, B, X, Y): 非0→ON, 0→OFF *)
                (*   true=1 / false=nil=0 なので値だけで判定できる *)
                IF Z5 = 0 THEN
                  IF Z8 = 2 THEN
                    D0Z6 := VMTEMP32;
                    D1Z6 := VMTEMP32HI;
                  ELSIF Z8 = 1 THEN
                    D0Z6 := DINT_TO_INT(VMTEMP32L);
                  ELSIF Z8 = 3 THEN
                    D0Z6 := VMTEMP32;
                    D1Z6 := VMTEMP32HI;
                  ELSIF Z8 = 4 THEN
                    D0Z6 := VMTEMP32B;
                    D1Z6 := VMTEMP32BHI;
                  ELSE
                    D0Z6 := DINT_TO_INT(VMTEMP32L);
                  END_IF;
                ELSIF Z5 = 1 THEN
                  IF Z8 = 2 THEN
                    W0Z6 := VMTEMP32;
                    W1Z6 := VMTEMP32HI;
                  ELSIF Z8 = 1 THEN
                    W0Z6 := DINT_TO_INT(VMTEMP32L);
                  ELSIF Z8 = 3 THEN
                    W0Z6 := VMTEMP32;
                    W1Z6 := VMTEMP32HI;
                  ELSIF Z8 = 4 THEN
                    W0Z6 := VMTEMP32B;
                    W1Z6 := VMTEMP32BHI;
                  ELSE
                    W0Z6 := DINT_TO_INT(VMTEMP32L);
                  END_IF;
                ELSIF Z5 = 2 THEN
                  IF Z8 = 2 THEN
                    R0Z6 := VMTEMP32;
                    R1Z6 := VMTEMP32HI;
                  ELSIF Z8 = 1 THEN
                    R0Z6 := DINT_TO_INT(VMTEMP32L);
                  ELSIF Z8 = 3 THEN
                    R0Z6 := VMTEMP32;
                    R1Z6 := VMTEMP32HI;
                  ELSIF Z8 = 4 THEN
                    R0Z6 := VMTEMP32B;
                    R1Z6 := VMTEMP32BHI;
                  ELSE
                    R0Z6 := DINT_TO_INT(VMTEMP32L);
                  END_IF;
                ELSIF Z5 = 3 THEN
                  IF Z8 = 2 THEN
                    ZR0Z6 := VMTEMP32;
                    ZR1Z6 := VMTEMP32HI;
                  ELSIF Z8 = 1 THEN
                    ZR0Z6 := DINT_TO_INT(VMTEMP32L);
                  ELSIF Z8 = 3 THEN
                    ZR0Z6 := VMTEMP32;
                    ZR1Z6 := VMTEMP32HI;
                  ELSIF Z8 = 4 THEN
                    ZR0Z6 := VMTEMP32B;
                    ZR1Z6 := VMTEMP32BHI;
                  ELSE
                    ZR0Z6 := DINT_TO_INT(VMTEMP32L);
                  END_IF;
                ELSIF Z5 = 4 THEN
                  IF Z8 = 5 THEN
                    IF VMTEMP32L <> 0 THEN
                      M0Z6 := TRUE;
                    ELSE
                      M0Z6 := FALSE;
                    END_IF;
                  ELSE
                    IF Z8 = 2 THEN
                      K8M0Z6 := VMTEMP32L;
                    ELSIF Z8 = 1 THEN
                      K4M0Z6 := DINT_TO_INT(VMTEMP32L);
                    ELSIF Z8 = 3 THEN
                      K8M0Z6 := VMTEMP32L;
                    ELSIF Z8 = 4 THEN
                      K8M0Z6 := VMTEMP32BL;
                    ELSE
                      K4M0Z6 := DINT_TO_INT(VMTEMP32L);
                    END_IF;
                  END_IF;
                ELSIF Z5 = 5 THEN
                  IF Z8 = 5 THEN
                    IF VMTEMP32L <> 0 THEN
                      L0Z6 := TRUE;
                    ELSE
                      L0Z6 := FALSE;
                    END_IF;
                  ELSE
                    IF Z8 = 2 THEN
                      K8L0Z6 := VMTEMP32L;
                    ELSIF Z8 = 1 THEN
                      K4L0Z6 := DINT_TO_INT(VMTEMP32L);
                    ELSIF Z8 = 3 THEN
                      K8L0Z6 := VMTEMP32L;
                    ELSIF Z8 = 4 THEN
                      K8L0Z6 := VMTEMP32BL;
                    ELSE
                      K4L0Z6 := DINT_TO_INT(VMTEMP32L);
                    END_IF;
                  END_IF;
                ELSIF Z5 = 6 THEN
                  IF Z8 = 5 THEN
                    IF VMTEMP32L <> 0 THEN
                      B0Z6 := TRUE;
                    ELSE
                      B0Z6 := FALSE;
                    END_IF;
                  ELSE
                    IF Z8 = 2 THEN
                      K8B0Z6 := VMTEMP32L;
                    ELSIF Z8 = 1 THEN
                      K4B0Z6 := DINT_TO_INT(VMTEMP32L);
                    ELSIF Z8 = 3 THEN
                      K8B0Z6 := VMTEMP32L;
                    ELSIF Z8 = 4 THEN
                      K8B0Z6 := VMTEMP32BL;
                    ELSE
                      K4B0Z6 := DINT_TO_INT(VMTEMP32L);
                    END_IF;
                  END_IF;
                ELSIF Z5 = 7 THEN
                  IF Z8 = 5 THEN
                    IF VMTEMP32L <> 0 THEN
                      X0Z6 := TRUE;
                    ELSE
                      X0Z6 := FALSE;
                    END_IF;
                  ELSE
                    IF Z8 = 2 THEN
                      K8X0Z6 := VMTEMP32L;
                    ELSIF Z8 = 1 THEN
                      K4X0Z6 := DINT_TO_INT(VMTEMP32L);
                    ELSIF Z8 = 3 THEN
                      K8X0Z6 := VMTEMP32L;
                    ELSIF Z8 = 4 THEN
                      K8X0Z6 := VMTEMP32BL;
                    ELSE
                      K4X0Z6 := DINT_TO_INT(VMTEMP32L);
                    END_IF;
                  END_IF;
                ELSIF Z5 = 8 THEN
                  IF Z8 = 5 THEN
                    IF VMTEMP32L <> 0 THEN
                      Y0Z6 := TRUE;
                    ELSE
                      Y0Z6 := FALSE;
                    END_IF;
                  ELSE
                    IF Z8 = 2 THEN
                      K8Y0Z6 := VMTEMP32L;
                    ELSIF Z8 = 1 THEN
                      K4Y0Z6 := DINT_TO_INT(VMTEMP32L);
                    ELSIF Z8 = 3 THEN
                      K8Y0Z6 := VMTEMP32L;
                    ELSIF Z8 = 4 THEN
                      K8Y0Z6 := VMTEMP32BL;
                    ELSE
                      K4Y0Z6 := DINT_TO_INT(VMTEMP32L);
                    END_IF;
                  END_IF;
                ELSE
                  (* 呼ぶ側が種別を確かめている。ここへは来ない *)
                  VMDISPATCH := 0;
                END_IF;
              END_IF;
            END_FOR;
          END_IF;
          IF VMSTRFLAG = 1 THEN
            (* 数値でない要素があった。入れ子の書き出し方は決めていない *)
            VMSTATUS := 3;
            VMERROR := 2;
            EXIT;
          END_IF;
        ELSIF VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLTAG = 9 THEN
          (* ハッシュはデバイスへ写せない。鍵の並べ方が決まらない *)
          VMSTATUS := 3;
          VMERROR := 2;
          EXIT;
        ELSIF Z8 >= 6 THEN
          (* 文字列の桁 (T) に文字列以外を書こうとした *)
          VMSTATUS := 3;
          VMERROR := 2;
          EXIT;
        ELSE
          (* レジスタの値を書き込み先の幅に合わせて変換する *)
          (* 使う側の形だけを作る。Infinity や NaN の整数変換は *)
          (* 浮動小数点フォーマット異常になるため、.F 書き込みでは行わない *)
          IF Z8 = 4 THEN
            IF VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLTAG = 5 THEN
              VMTEMP32BF := VMSLOTF[VMREGSLOT + VMOPERANDA + 2].SLNUM;
            ELSE
              VMTEMP32BF := DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLNUM);   (* 整数→実数 *)
            END_IF;
          ELSE
            IF VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLTAG = 5 THEN
              VMTEMP32L := REAL_TO_DINT(VMSLOTF[VMREGSLOT + VMOPERANDA + 2].SLNUM);   (* 実数→整数 (0方向へ切り捨て) *)
              (* この機種の実数→整数は四捨五入。0 方向へ 1 だけ戻す *)
              IF VMSLOTF[VMREGSLOT + VMOPERANDA + 2].SLNUM >= 0.0 THEN
                IF DINT_TO_REAL(VMTEMP32L) > VMSLOTF[VMREGSLOT + VMOPERANDA + 2].SLNUM THEN
                  VMTEMP32L := VMTEMP32L - 1;
                END_IF;
              ELSE
                IF DINT_TO_REAL(VMTEMP32L) < VMSLOTF[VMREGSLOT + VMOPERANDA + 2].SLNUM THEN
                  VMTEMP32L := VMTEMP32L + 1;
                END_IF;
              END_IF;
            ELSE
              VMTEMP32L := VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLNUM;
            END_IF;
          END_IF;
          (* デバイスタイプ別書き込み *)
          (* ワードデバイス (EM, DM, ZF): Z8 (access_type) で幅を選ぶ *)
          (*   2=.L(32bit符号付き) *)
          (*   1=.U(16bit符号なし) *)
          (*   3=.D(32bit符号なし) *)
          (*   4=.F(実数) *)
          (*   それ以外=.S(16bit符号付き/既定) *)
          (* ビットデバイス (M, L, B, X, Y): 非0→ON, 0→OFF *)
          (*   true=1 / false=nil=0 なので値だけで判定できる *)
          IF Z5 = 0 THEN
            IF Z8 = 2 THEN
              D0Z6 := VMTEMP32;
              D1Z6 := VMTEMP32HI;
            ELSIF Z8 = 1 THEN
              D0Z6 := DINT_TO_INT(VMTEMP32L);
            ELSIF Z8 = 3 THEN
              D0Z6 := VMTEMP32;
              D1Z6 := VMTEMP32HI;
            ELSIF Z8 = 4 THEN
              D0Z6 := VMTEMP32B;
              D1Z6 := VMTEMP32BHI;
            ELSE
              D0Z6 := DINT_TO_INT(VMTEMP32L);
            END_IF;
          ELSIF Z5 = 1 THEN
            IF Z8 = 2 THEN
              W0Z6 := VMTEMP32;
              W1Z6 := VMTEMP32HI;
            ELSIF Z8 = 1 THEN
              W0Z6 := DINT_TO_INT(VMTEMP32L);
            ELSIF Z8 = 3 THEN
              W0Z6 := VMTEMP32;
              W1Z6 := VMTEMP32HI;
            ELSIF Z8 = 4 THEN
              W0Z6 := VMTEMP32B;
              W1Z6 := VMTEMP32BHI;
            ELSE
              W0Z6 := DINT_TO_INT(VMTEMP32L);
            END_IF;
          ELSIF Z5 = 2 THEN
            IF Z8 = 2 THEN
              R0Z6 := VMTEMP32;
              R1Z6 := VMTEMP32HI;
            ELSIF Z8 = 1 THEN
              R0Z6 := DINT_TO_INT(VMTEMP32L);
            ELSIF Z8 = 3 THEN
              R0Z6 := VMTEMP32;
              R1Z6 := VMTEMP32HI;
            ELSIF Z8 = 4 THEN
              R0Z6 := VMTEMP32B;
              R1Z6 := VMTEMP32BHI;
            ELSE
              R0Z6 := DINT_TO_INT(VMTEMP32L);
            END_IF;
          ELSIF Z5 = 3 THEN
            IF Z8 = 2 THEN
              ZR0Z6 := VMTEMP32;
              ZR1Z6 := VMTEMP32HI;
            ELSIF Z8 = 1 THEN
              ZR0Z6 := DINT_TO_INT(VMTEMP32L);
            ELSIF Z8 = 3 THEN
              ZR0Z6 := VMTEMP32;
              ZR1Z6 := VMTEMP32HI;
            ELSIF Z8 = 4 THEN
              ZR0Z6 := VMTEMP32B;
              ZR1Z6 := VMTEMP32BHI;
            ELSE
              ZR0Z6 := DINT_TO_INT(VMTEMP32L);
            END_IF;
          ELSIF Z5 = 4 THEN
            IF Z8 = 5 THEN
              IF VMTEMP32L <> 0 THEN
                M0Z6 := TRUE;
              ELSE
                M0Z6 := FALSE;
              END_IF;
            ELSE
              IF Z8 = 2 THEN
                K8M0Z6 := VMTEMP32L;
              ELSIF Z8 = 1 THEN
                K4M0Z6 := DINT_TO_INT(VMTEMP32L);
              ELSIF Z8 = 3 THEN
                K8M0Z6 := VMTEMP32L;
              ELSIF Z8 = 4 THEN
                K8M0Z6 := VMTEMP32BL;
              ELSE
                K4M0Z6 := DINT_TO_INT(VMTEMP32L);
              END_IF;
            END_IF;
          ELSIF Z5 = 5 THEN
            IF Z8 = 5 THEN
              IF VMTEMP32L <> 0 THEN
                L0Z6 := TRUE;
              ELSE
                L0Z6 := FALSE;
              END_IF;
            ELSE
              IF Z8 = 2 THEN
                K8L0Z6 := VMTEMP32L;
              ELSIF Z8 = 1 THEN
                K4L0Z6 := DINT_TO_INT(VMTEMP32L);
              ELSIF Z8 = 3 THEN
                K8L0Z6 := VMTEMP32L;
              ELSIF Z8 = 4 THEN
                K8L0Z6 := VMTEMP32BL;
              ELSE
                K4L0Z6 := DINT_TO_INT(VMTEMP32L);
              END_IF;
            END_IF;
          ELSIF Z5 = 6 THEN
            IF Z8 = 5 THEN
              IF VMTEMP32L <> 0 THEN
                B0Z6 := TRUE;
              ELSE
                B0Z6 := FALSE;
              END_IF;
            ELSE
              IF Z8 = 2 THEN
                K8B0Z6 := VMTEMP32L;
              ELSIF Z8 = 1 THEN
                K4B0Z6 := DINT_TO_INT(VMTEMP32L);
              ELSIF Z8 = 3 THEN
                K8B0Z6 := VMTEMP32L;
              ELSIF Z8 = 4 THEN
                K8B0Z6 := VMTEMP32BL;
              ELSE
                K4B0Z6 := DINT_TO_INT(VMTEMP32L);
              END_IF;
            END_IF;
          ELSIF Z5 = 7 THEN
            IF Z8 = 5 THEN
              IF VMTEMP32L <> 0 THEN
                X0Z6 := TRUE;
              ELSE
                X0Z6 := FALSE;
              END_IF;
            ELSE
              IF Z8 = 2 THEN
                K8X0Z6 := VMTEMP32L;
              ELSIF Z8 = 1 THEN
                K4X0Z6 := DINT_TO_INT(VMTEMP32L);
              ELSIF Z8 = 3 THEN
                K8X0Z6 := VMTEMP32L;
              ELSIF Z8 = 4 THEN
                K8X0Z6 := VMTEMP32BL;
              ELSE
                K4X0Z6 := DINT_TO_INT(VMTEMP32L);
              END_IF;
            END_IF;
          ELSIF Z5 = 8 THEN
            IF Z8 = 5 THEN
              IF VMTEMP32L <> 0 THEN
                Y0Z6 := TRUE;
              ELSE
                Y0Z6 := FALSE;
              END_IF;
            ELSE
              IF Z8 = 2 THEN
                K8Y0Z6 := VMTEMP32L;
              ELSIF Z8 = 1 THEN
                K4Y0Z6 := DINT_TO_INT(VMTEMP32L);
              ELSIF Z8 = 3 THEN
                K8Y0Z6 := VMTEMP32L;
              ELSIF Z8 = 4 THEN
                K8Y0Z6 := VMTEMP32BL;
              ELSE
                K4Y0Z6 := DINT_TO_INT(VMTEMP32L);
              END_IF;
            END_IF;
          ELSE
            VMSTATUS := 3;
            VMERROR := 2;
            EXIT;
          END_IF;
        END_IF;
      ELSIF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 8 THEN
        (* スロットの見出し。R[a] を書き換える前に読む *)
        Z4 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM);
        Z4 := Z4 * 50 + 5000;
        VMTEMP32BL := INT_TO_DINT(D0Z4);   (* 要素数 *)
        (* 負の添字は後ろから数える (Ruby の a[-1] は最後の要素) *)
        VMTEMP32L := VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM;
        IF VMTEMP32L < 0 THEN
          VMTEMP32L := VMTEMP32L + VMTEMP32BL;
        END_IF;
        IF VMTEMP32L < 0 THEN
          (* 後ろから数えても先頭より前 (Ruby は IndexError) *)
          VMSTATUS := 3;
          VMERROR := 2;
          EXIT;
        END_IF;
        IF VMTEMP32L >= 12 THEN
          (* 1 スロットの容量を超える位置 *)
          VMSTATUS := 3;
          VMERROR := 10;
          EXIT;
        END_IF;
        (* 要素数を超える位置への代入は、間を nil で埋めて伸ばす *)
        IF VMTEMP32L > VMTEMP32BL THEN
          Z6 := DINT_TO_INT(VMTEMP32BL);   (* 埋め始め (今の要素数) *)
          Z7 := DINT_TO_INT(VMTEMP32L);
          Z7 := Z7 - 1;   (* 埋め終わり。ここは添字 > 要素数 >= 0 なので 0 未満にならない *)
          FOR Z8 := Z6 TO Z7 DO
            Z5 := Z8 * 4 + Z4 + 2;
            VMSLOT[Z5 / 4].SLNUM := 0;
            VMSLOT[Z5 / 4].SLTAG := 1;
          END_FOR;
        END_IF;
        IF VMTEMP32L >= VMTEMP32BL THEN
          Z6 := DINT_TO_INT(VMTEMP32L);
          D0Z4 := Z6 + 1;   (* 要素数を伸ばす *)
        END_IF;
        Z5 := DINT_TO_INT(VMTEMP32L);
        Z5 := Z5 * 4 + Z4 + 2;
        VMSLOT[Z5 / 4].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLNUM;
        VMSLOT[Z5 / 4].SLTAG := VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLTAG;
      ELSIF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 9 THEN
        (* 鍵の配列の見出し。R[a] を書き換える前に読む *)
        Z4 := VMSLOTW[VMREGSLOT + VMOPERANDA].SLW0;
        Z4 := Z4 * 50 + 5000;
        VMTEMP32BL := INT_TO_DINT(D0Z4);   (* 組の数 *)
        Z5 := VMSLOTW[VMREGSLOT + VMOPERANDA].SLW1;   (* 値の配列 *)
        Z5 := Z5 * 50 + 5000;
        (* 鍵を先頭から探す。一致は型と値の両方 (Ruby の eql? と同じ) *)
        VMTEMP32L := -1;
        IF VMTEMP32BL > 0 THEN
          Z8 := DINT_TO_INT(VMTEMP32BL);
          Z8 := Z8 - 1;
          FOR Z6 := 0 TO Z8 DO
            IF VMTEMP32L < 0 THEN
              (* 最初に一致したものを採る *)
              Z7 := Z6 * 4 + Z4 + 2;
              IF VMSLOT[Z7 / 4].SLTAG = VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG THEN
                IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 7 THEN
                  (* 文字列の鍵は中身で照合する。スロットが違っても同じ鍵 *)
                  (* 文字列は中身で比べる。スロット番号ではない *)
                  (* Z3 を借りる。返すまでの間に呼ぶ側の値を壊さないため *)
                  VMSTRSAVEDZ := Z3;
                  VMSTRFLAG := 0;
                  Z3 := DINT_TO_INT(VMSLOT[Z7 / 4].SLNUM);
                  Z3 := Z3 * 50 + 5000;
                  VMSTRTEMP := D0Z3;   (* バイト数 *)
                  Z3 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM);
                  Z3 := Z3 * 50 + 5000;
                  IF VMSTRTEMP = D0Z3 THEN
                    (* バイト数が同じ。ここから中身を見る *)
                    VMSTRFLAG := 1;
                    VMSTRLIMIT := VMSTRTEMP + 1;
                    VMSTRLIMIT := VMSTRLIMIT / 2;   (* ワード数 *)
                    IF VMSTRLIMIT > 0 THEN
                      VMSTRLIMIT := VMSTRLIMIT - 1;
                      FOR VMSTRINDEX := 0 TO VMSTRLIMIT DO
                        Z3 := DINT_TO_INT(VMSLOT[Z7 / 4].SLNUM);
                        Z3 := Z3 * 50 + 5000;
                        Z3 := VMSTRINDEX + Z3 + 2;
                        VMSTRTEMP := D0Z3;
                        Z3 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM);
                        Z3 := Z3 * 50 + 5000;
                        Z3 := VMSTRINDEX + Z3 + 2;
                        IF VMSTRTEMP <> D0Z3 THEN
                          VMSTRFLAG := 0;
                        END_IF;
                      END_FOR;
                    END_IF;
                  END_IF;
                  (* 借りた Z3 を返す *)
                  Z3 := VMSTRSAVEDZ;
                  IF VMSTRFLAG = 1 THEN
                    VMTEMP32L := INT_TO_DINT(Z6);
                  END_IF;
                ELSE
                  IF VMSLOT[Z7 / 4].SLNUM = VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
                    VMTEMP32L := INT_TO_DINT(Z6);
                  END_IF;
                END_IF;
              END_IF;
            END_IF;
          END_FOR;
        END_IF;
        IF VMTEMP32L >= 0 THEN
          (* 既にある鍵は値だけ差し替える *)
          Z7 := DINT_TO_INT(VMTEMP32L);
          Z7 := Z7 * 4 + Z5 + 2;
          VMSLOT[Z7 / 4].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLNUM;
          VMSLOT[Z7 / 4].SLTAG := VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLTAG;
        ELSE
          (* 新しい鍵は鍵と値の両方の末尾に足す *)
          IF VMTEMP32BL >= 12 THEN
            (* 1 スロットの容量がいっぱい *)
            VMSTATUS := 3;
            VMERROR := 10;
            EXIT;
          END_IF;
          VMTEMP32L := VMTEMP32BL;
          Z7 := DINT_TO_INT(VMTEMP32L);
          Z7 := Z7 * 4 + Z4 + 2;
          VMSLOT[Z7 / 4].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM;
          VMSLOT[Z7 / 4].SLTAG := VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG;
          Z7 := DINT_TO_INT(VMTEMP32L);
          Z7 := Z7 * 4 + Z5 + 2;
          VMSLOT[Z7 / 4].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLNUM;
          VMSLOT[Z7 / 4].SLTAG := VMSLOT[VMREGSLOT + VMOPERANDA + 2].SLTAG;
          Z8 := DINT_TO_INT(VMTEMP32BL);
          Z8 := Z8 + 1;   (* 組の数を 1 増やす *)
          D0Z4 := Z8;
          D0Z5 := Z8;
        END_IF;
      ELSE
        (* デバイス参照・配列・ハッシュ以外への添字代入は未対応 *)
        VMSTATUS := 3;
        VMERROR := 2;
        EXIT;
      END_IF;

    ELSE
      (* 未知のオペコード: エラー *)
      VMSTATUS := 3;
      VMERROR := VMCURRENTOPCODE;
      EXIT;

    END_IF;
  ELSIF VMCURRENTOPCODE <= 60 THEN
    (* オペコード 0x25 - 0x3C *)
    IF VMCURRENTOPCODE = 37 THEN
      (* OP_JMP (S): PC += signed16(a) *)
      (* 16bit big-endian: hi byte, lo byte *)
      Z3 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      Z4 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDA := Z3 * 256 + Z4;
      VMPC := VMPC + VMOPERANDA;

    ELSIF VMCURRENTOPCODE = 38 THEN
      (* OP_JMPIF (BS): if R[a] が真 then PC += signed16(b) *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      (* 16bit big-endian: hi byte, lo byte *)
      Z3 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      Z4 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDB := Z3 * 256 + Z4;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG > 2 THEN
        VMPC := VMPC + VMOPERANDB;
      END_IF;

    ELSIF VMCURRENTOPCODE = 39 THEN
      (* OP_JMPNOT (BS): if R[a] が偽 (nil/false) then PC += signed16(b) *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      (* 16bit big-endian: hi byte, lo byte *)
      Z3 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      Z4 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDB := Z3 * 256 + Z4;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG <= 2 THEN
        VMPC := VMPC + VMOPERANDB;
      END_IF;

    ELSIF VMCURRENTOPCODE = 40 THEN
      (* OP_JMPNIL (BS): if R[a] が nil then PC += signed16(b) *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      (* 16bit big-endian: hi byte, lo byte *)
      Z3 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      Z4 := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDB := Z3 * 256 + Z4;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 1 THEN
        VMPC := VMPC + VMOPERANDB;
      END_IF;

    ELSIF VMCURRENTOPCODE = 56 THEN
      (* OP_RETURN (B): R[b] を返して呼び出し元へ (トップレベルでは VM 停止) *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      IF VMFRAMESP = 0 THEN
        (* トップレベルの return は VM 停止 *)
        VMSTATUS := 2;
        EXIT;
      ELSE
        Z3 := (VMFRAMESP - 1) * 10 + 376 + Z9;
        IF D5Z3 >= 1 THEN
          VMTEMP32 := D6Z3;
          VMTEMP32HI := D7Z3;
          VMTEMP32L := VMTEMP32L + 1;
          VMTEMP32B := D8Z3;
          VMTEMP32BHI := D9Z3;
          IF VMTEMP32L <= VMTEMP32BL THEN
            (* 次の回。PC を 0 に戻し、ブロックの引数を更新するだけ *)
            (* irep もレジスタ窓もそのまま使い回す *)
            D6Z3 := VMTEMP32;
            D7Z3 := VMTEMP32HI;
            Z2 := 4 + VMREGBASE + 4000;
            IF D5Z3 = 3 THEN
              (* h.each は鍵と値を渡す。レシーバのハッシュは R[0] に残っている *)
              Z4 := 0 + VMREGBASE + 4000;
              Z7 := VMSLOTW[Z4 / 4].SLW0;   (* スロット番号 *)
              Z7 := Z7 * 50 + 5000;
              Z5 := DINT_TO_INT(VMTEMP32L);
              Z5 := Z5 * 4 + Z7 + 2;
              VMSLOT[Z2 / 4].SLNUM := VMSLOT[Z5 / 4].SLNUM;
              VMSLOT[Z2 / 4].SLTAG := VMSLOT[Z5 / 4].SLTAG;
              Z2 := 2 * 4 + VMREGBASE + 4000;   (* R[2] に値 *)
              Z7 := VMSLOTW[Z4 / 4].SLW1;   (* スロット番号 *)
              Z7 := Z7 * 50 + 5000;
              Z5 := DINT_TO_INT(VMTEMP32L);
              Z5 := Z5 * 4 + Z7 + 2;
              VMSLOT[Z2 / 4].SLNUM := VMSLOT[Z5 / 4].SLNUM;
              VMSLOT[Z2 / 4].SLTAG := VMSLOT[Z5 / 4].SLTAG;
              VMCALLARGC := 2;
            ELSIF D5Z3 = 2 THEN
              (* a.each はその位置の要素を渡す。レシーバの配列は R[0] に残っている *)
              Z4 := 0 + VMREGBASE + 4000;
              VMTEMP32 := D1Z4;
              VMTEMP32HI := D2Z4;
              Z7 := DINT_TO_INT(VMTEMP32L);   (* スロット番号 *)
              Z7 := Z7 * 50 + 5000;
              Z5 := DINT_TO_INT(VMTEMP32L);
              Z5 := Z5 * 4 + Z7 + 2;
              VMSLOT[Z2 / 4].SLNUM := VMSLOT[Z5 / 4].SLNUM;
              VMSLOT[Z2 / 4].SLTAG := VMSLOT[Z5 / 4].SLTAG;
              VMCALLARGC := 1;
            ELSE
              (* times / upto は添字を渡す *)
              VMSLOT[Z2 / 4].SLNUM := VMTEMP32L;
              VMSLOT[Z2 / 4].SLTAG := 4;
              VMCALLARGC := 1;
            END_IF;
            VMPC := 0;
          ELSE
            (* 反復の終わり。R[0] にはレシーバが残っており、それが呼び出しの値になる *)
            VMFRAMESP := VMFRAMESP - 1;
            (* 外した段がそのまま戻り先。減らした後なので top_frame_expr ではない *)
            Z3 := VMFRAMESP * 10 + 376 + Z9;
            VMPC := D0Z3;
            Z5 := D1Z3;
            VMREGBASE := D2Z3;
            VMCURIREP := Z5;
            (* IREP テーブルから実行中の irep の情報を写す *)
            Z1 := Z5 * 8 + VMIREPTABLE;
            VMCURBYTECODE := ZR0Z1;
            VMBYTECODELEN := ZR1Z1;
            VMCURPOOL := ZR2Z1;
            VMCURSYMBOLS := ZR3Z1;
            VMNREGS := ZR4Z1;
          END_IF;
        ELSE
          (* R[a] を R[0] へ写す。R[0] は呼んだ側の R[a] と同じ場所なので *)
          (* これで戻り値が呼び出し元から見える位置に入る *)
          VMSLOT[VMREGSLOT + 0].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM;
          VMSLOT[VMREGSLOT + 0].SLTAG := VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG;
          VMFRAMESP := VMFRAMESP - 1;
          (* 外した段がそのまま戻り先。減らした後なので top_frame_expr ではない *)
          Z3 := VMFRAMESP * 10 + 376 + Z9;
          VMPC := D0Z3;
          Z5 := D1Z3;
          VMREGBASE := D2Z3;
          VMCURIREP := Z5;
          (* IREP テーブルから実行中の irep の情報を写す *)
          Z1 := Z5 * 8 + VMIREPTABLE;
          VMCURBYTECODE := ZR0Z1;
          VMBYTECODELEN := ZR1Z1;
          VMCURPOOL := ZR2Z1;
          VMCURSYMBOLS := ZR3Z1;
          VMNREGS := ZR4Z1;
        END_IF;
      END_IF;

    ELSIF VMCURRENTOPCODE = 60 THEN
      (* OP_ADD (B): R[a] = R[a] + R[a+1] *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 5 THEN
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM + VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
        ELSE
          VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM + DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM);
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
        END_IF;
      ELSE
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM) + VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
        ELSE
          IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 7 THEN
            (* プールの空きスロットを取る。返さないので使い切ったら止まる *)
            IF VMARRAYSP >= 16 THEN
              VMSTATUS := 3;
              VMERROR := 10;
              EXIT;
            END_IF;
            Z4 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM);
            Z4 := Z4 * 50 + 5000;
            VMTEMP32L := INT_TO_DINT(D0Z4);
            Z5 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM);
            Z5 := Z5 * 50 + 5000;
            VMTEMP32BL := INT_TO_DINT(D0Z5);
            (* 1 スロットに収まること *)
            Z6 := DINT_TO_INT(VMTEMP32L) + DINT_TO_INT(VMTEMP32BL);
            IF Z6 > 96 THEN
              VMSTATUS := 3;
              VMERROR := 10;
              EXIT;
            END_IF;
            (* 新しいスロットへ左側をワード単位で写す。並びが同じなのでそのまま *)
            Z3 := VMARRAYSP * 50 + 5000;
            D0Z3 := DINT_TO_INT(VMTEMP32L);
            VMSTRLIMIT := DINT_TO_INT(VMTEMP32L) + 1;
            VMSTRLIMIT := VMSTRLIMIT / 2;
            IF VMSTRLIMIT > 0 THEN
              VMSTRLIMIT := VMSTRLIMIT - 1;
              FOR VMSTRINDEX := 0 TO VMSTRLIMIT DO
                Z7 := VMSTRINDEX + Z4 + 2;
                Z8 := VMSTRINDEX + Z3 + 2;
                D0Z8 := D0Z7;
              END_FOR;
            END_IF;
            (* 右側を継ぎ足す。Z4 を継ぎ足す元にする *)
            Z4 := Z5;
            IF VMTEMP32BL > 0 THEN
              Z6 := DINT_TO_INT(VMTEMP32BL);
              Z6 := Z6 - 1;
              FOR Z5 := 0 TO Z6 DO
                (* 継ぎ足す元のバイトを 1 つ取り出す *)
                Z7 := Z5 / 2;
                Z8 := Z7 + Z4 + 2;
                Z8 := D0Z8;
                Z7 := Z7 * 2;
                IF Z5 = Z7 THEN
                  Z8 := Z8 / 256;   (* 偶数の位置は上位バイト *)
                ELSE
                  Z7 := Z8 / 256;
                  Z8 := Z8 - Z7 * 256;   (* 奇数の位置は下位バイト *)
                END_IF;
                (* 書き先の位置 (継ぎ足す先の長さ + 何バイト目か) *)
                VMSTRTEMP := DINT_TO_INT(VMTEMP32L) + Z5;
                Z7 := VMSTRTEMP;
                Z7 := Z7 / 2;
                Z7 := Z7 + Z3 + 2;
                VMSTRLIMIT := VMSTRTEMP / 2;
                VMSTRLIMIT := VMSTRLIMIT * 2;
                IF VMSTRTEMP = VMSTRLIMIT THEN
                  (* 偶数。下位バイトは 0 にしておく (次のバイトか詰め物が入る) *)
                  D0Z7 := Z8 * 256;
                ELSE
                  (* 奇数。上位バイトを残して下位に入れる *)
                  VMSTRLIMIT := D0Z7;
                  VMSTRLIMIT := VMSTRLIMIT / 256;
                  D0Z7 := VMSTRLIMIT * 256 + Z8;
                END_IF;
              END_FOR;
            END_IF;
            (* 長さを更新する *)
            VMTEMP32L := VMTEMP32L + VMTEMP32BL;
            D0Z3 := DINT_TO_INT(VMTEMP32L);
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := INT_TO_DINT(VMARRAYSP);   (* スロット番号 *)
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 7;
            VMARRAYSP := VMARRAYSP + 1;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM + VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          END_IF;
        END_IF;
      END_IF;

    ELSE
      (* 未知のオペコード: エラー *)
      VMSTATUS := 3;
      VMERROR := VMCURRENTOPCODE;
      EXIT;

    END_IF;
  ELSIF VMCURRENTOPCODE <= 66 THEN
    (* オペコード 0x3D - 0x42 *)
    IF VMCURRENTOPCODE = 61 THEN
      (* OP_ADDI (BB): R[a] = R[a] + b *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDB := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 5 THEN
        VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM + INT_TO_REAL(VMOPERANDB);
        VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
      ELSE
        VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM + INT_TO_DINT(VMOPERANDB);
        VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
      END_IF;

    ELSIF VMCURRENTOPCODE = 62 THEN
      (* OP_SUB (B): R[a] = R[a] - R[a+1] *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 5 THEN
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM - VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
        ELSE
          VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM - DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM);
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
        END_IF;
      ELSE
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM) - VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
        ELSE
          VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM - VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
        END_IF;
      END_IF;

    ELSIF VMCURRENTOPCODE = 63 THEN
      (* OP_SUBI (BB): R[a] = R[a] - b *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      VMOPERANDB := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 5 THEN
        VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM - INT_TO_REAL(VMOPERANDB);
        VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
      ELSE
        VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM - INT_TO_DINT(VMOPERANDB);
        VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
      END_IF;

    ELSIF VMCURRENTOPCODE = 64 THEN
      (* OP_MUL (B): R[a] = R[a] * R[a+1] *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 5 THEN
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM * VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
        ELSE
          VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM * DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM);
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
        END_IF;
      ELSE
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM) * VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
        ELSE
          VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM * VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
        END_IF;
      END_IF;

    ELSIF VMCURRENTOPCODE = 65 THEN
      (* OP_DIV (B): R[a] = R[a] / R[a+1] *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 5 THEN
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          IF VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM <> 0.0 THEN
            VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM / VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM;
          ELSE
            (* 0 除算。KV の / は CR2012 を出すため実行せず、 *)
            (* IEEE754 の無限大 / 非数のビット列を直接置く *)
            (* 代入先は被除数と同じレジスタなので、先に符号から上位ワードを決める。 *)
            (* 被除数を書き換えてから符号を見ると、低位ワードを消した時点で *)
            (* 整数の 1-65535 が 0 になり、+Infinity が NaN になる *)
            VMTEMP32 := 32704;   (* 既定は NaN (0.0 / 0.0) *)
            IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM > 0.0 THEN
              VMTEMP32 := 32640;   (* +Infinity *)
            END_IF;
            IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM < 0.0 THEN
              VMTEMP32 := -128;   (* -Infinity *)
            END_IF;
            VMSLOTW[VMREGSLOT + VMOPERANDA].SLW0 := 0;
            VMSLOTW[VMREGSLOT + VMOPERANDA].SLW1 := VMTEMP32;
          END_IF;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
        ELSE
          IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM <> 0 THEN
            VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM / DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM);
          ELSE
            (* 0 除算。KV の / は CR2012 を出すため実行せず、 *)
            (* IEEE754 の無限大 / 非数のビット列を直接置く *)
            (* 代入先は被除数と同じレジスタなので、先に符号から上位ワードを決める。 *)
            (* 被除数を書き換えてから符号を見ると、低位ワードを消した時点で *)
            (* 整数の 1-65535 が 0 になり、+Infinity が NaN になる *)
            VMTEMP32 := 32704;   (* 既定は NaN (0.0 / 0.0) *)
            IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM > 0.0 THEN
              VMTEMP32 := 32640;   (* +Infinity *)
            END_IF;
            IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM < 0.0 THEN
              VMTEMP32 := -128;   (* -Infinity *)
            END_IF;
            VMSLOTW[VMREGSLOT + VMOPERANDA].SLW0 := 0;
            VMSLOTW[VMREGSLOT + VMOPERANDA].SLW1 := VMTEMP32;
          END_IF;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
        END_IF;
      ELSE
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          IF VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM <> 0.0 THEN
            VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM := DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM) / VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM;
          ELSE
            (* 0 除算。KV の / は CR2012 を出すため実行せず、 *)
            (* IEEE754 の無限大 / 非数のビット列を直接置く *)
            (* 代入先は被除数と同じレジスタなので、先に符号から上位ワードを決める。 *)
            (* 被除数を書き換えてから符号を見ると、低位ワードを消した時点で *)
            (* 整数の 1-65535 が 0 になり、+Infinity が NaN になる *)
            VMTEMP32 := 32704;   (* 既定は NaN (0.0 / 0.0) *)
            IF VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM > 0 THEN
              VMTEMP32 := 32640;   (* +Infinity *)
            END_IF;
            IF VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM < 0 THEN
              VMTEMP32 := -128;   (* -Infinity *)
            END_IF;
            VMSLOTW[VMREGSLOT + VMOPERANDA].SLW0 := 0;
            VMSLOTW[VMREGSLOT + VMOPERANDA].SLW1 := VMTEMP32;
          END_IF;
          VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 5;
        ELSE
          IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM <> 0 THEN
            (* Ruby の整数除算は切り下げ。KV の / は0方向へ切り捨てるため補正する *)
            VMTEMP32L := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM;   (* 被除数を退避 *)
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM / VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM;
            VMTEMP32BL := VMTEMP32L - VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM * VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM;   (* 余り *)
            IF VMTEMP32BL <> 0 THEN
              (* 符号が異なるときだけ切り下げになる *)
              IF VMTEMP32L < 0 THEN
                IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM > 0 THEN
                  VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM - 1;
                END_IF;
              ELSE
                IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM < 0 THEN
                  VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM - 1;
                END_IF;
              END_IF;
            END_IF;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 4;
          ELSE
            VMSTATUS := 3;
            VMERROR := 1;
            EXIT;
          END_IF;
        END_IF;
      END_IF;

    ELSIF VMCURRENTOPCODE = 66 THEN
      (* OP_EQ (B): R[a] = (R[a] == R[a+1]) ? true : false *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      (* 数値は型が違っても値で比べる (Ruby では 1 == 1.0 は真) *)
      (* 数値以外は型と値の両方が一致したときだけ真 (nil == false は偽) *)
      (* 結果を R[a] に書くと比較元が壊れるため、先に判定してから代入する *)
      VMTEMP32 := 0;
      (* シンボルや配列のタグは 4 より大きいので、上限も見ないと *)
      (* 番号やスロット番号が数値として比べられてしまう *)
      Z3 := 0;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG >= 4 THEN
        IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG <= 5 THEN
          Z3 := 1;
        END_IF;
      END_IF;
      Z4 := 0;
      IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG >= 4 THEN
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG <= 5 THEN
          Z4 := 1;
        END_IF;
      END_IF;
      IF Z3 = 1 THEN
        IF Z4 = 1 THEN
          IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 5 THEN
            IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
              IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM = VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
                VMTEMP32 := 1;
              END_IF;
            ELSE
              IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM = DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM) THEN
                VMTEMP32 := 1;
              END_IF;
            END_IF;
          ELSE
            IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
              IF DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM) = VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
                VMTEMP32 := 1;
              END_IF;
            ELSE
              IF VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM = VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
                VMTEMP32 := 1;
              END_IF;
            END_IF;
          END_IF;
        ELSE
          (* 数値と非数値は等しくない *)
          VMDISPATCH := 0;
        END_IF;
      ELSE
        IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG THEN
          IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 7 THEN
            (* 文字列は中身で比べる。スロット番号ではない *)
            (* Z3 を借りる。返すまでの間に呼ぶ側の値を壊さないため *)
            VMSTRSAVEDZ := Z3;
            VMSTRFLAG := 0;
            Z3 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM);
            Z3 := Z3 * 50 + 5000;
            VMSTRTEMP := D0Z3;   (* バイト数 *)
            Z3 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM);
            Z3 := Z3 * 50 + 5000;
            IF VMSTRTEMP = D0Z3 THEN
              (* バイト数が同じ。ここから中身を見る *)
              VMSTRFLAG := 1;
              VMSTRLIMIT := VMSTRTEMP + 1;
              VMSTRLIMIT := VMSTRLIMIT / 2;   (* ワード数 *)
              IF VMSTRLIMIT > 0 THEN
                VMSTRLIMIT := VMSTRLIMIT - 1;
                FOR VMSTRINDEX := 0 TO VMSTRLIMIT DO
                  Z3 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM);
                  Z3 := Z3 * 50 + 5000;
                  Z3 := VMSTRINDEX + Z3 + 2;
                  VMSTRTEMP := D0Z3;
                  Z3 := DINT_TO_INT(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM);
                  Z3 := Z3 * 50 + 5000;
                  Z3 := VMSTRINDEX + Z3 + 2;
                  IF VMSTRTEMP <> D0Z3 THEN
                    VMSTRFLAG := 0;
                  END_IF;
                END_FOR;
              END_IF;
            END_IF;
            (* 借りた Z3 を返す *)
            Z3 := VMSTRSAVEDZ;
            IF VMSTRFLAG = 1 THEN
              VMTEMP32 := 1;
            END_IF;
          ELSE
            IF VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM = VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
              VMTEMP32 := 1;
            END_IF;
          END_IF;
        END_IF;
      END_IF;
      IF VMTEMP32 = 1 THEN
        VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
        VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
      ELSE
        VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
        VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
      END_IF;

    ELSE
      (* 未知のオペコード: エラー *)
      VMSTATUS := 3;
      VMERROR := VMCURRENTOPCODE;
      EXIT;

    END_IF;
  ELSIF VMCURRENTOPCODE <= 105 THEN
    (* オペコード 0x43 - 0x69 *)
    IF VMCURRENTOPCODE = 67 THEN
      (* OP_LT (B): R[a] = (R[a] < R[a+1]) ? true : false *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 5 THEN
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM < VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        ELSE
          IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM < DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM) THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        END_IF;
      ELSE
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          IF DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM) < VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        ELSE
          IF VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM < VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        END_IF;
      END_IF;

    ELSIF VMCURRENTOPCODE = 68 THEN
      (* OP_LE (B): R[a] = (R[a] <= R[a+1]) ? true : false *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 5 THEN
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM <= VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        ELSE
          IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM <= DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM) THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        END_IF;
      ELSE
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          IF DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM) <= VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        ELSE
          IF VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM <= VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        END_IF;
      END_IF;

    ELSIF VMCURRENTOPCODE = 69 THEN
      (* OP_GT (B): R[a] = (R[a] > R[a+1]) ? true : false *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 5 THEN
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM > VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        ELSE
          IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM > DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM) THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        END_IF;
      ELSE
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          IF DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM) > VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        ELSE
          IF VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM > VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        END_IF;
      END_IF;

    ELSIF VMCURRENTOPCODE = 70 THEN
      (* OP_GE (B): R[a] = (R[a] >= R[a+1]) ? true : false *)
      VMOPERANDA := VMCODE[VMPC + VMCURBYTECODE];
      VMPC := VMPC + 1;
      IF VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG = 5 THEN
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM >= VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        ELSE
          IF VMSLOTF[VMREGSLOT + VMOPERANDA].SLNUM >= DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM) THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        END_IF;
      ELSE
        IF VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLTAG = 5 THEN
          IF DINT_TO_REAL(VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM) >= VMSLOTF[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        ELSE
          IF VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM >= VMSLOT[VMREGSLOT + VMOPERANDA + 1].SLNUM THEN
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 1;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 3;
          ELSE
            VMSLOT[VMREGSLOT + VMOPERANDA].SLNUM := 0;
            VMSLOT[VMREGSLOT + VMOPERANDA].SLTAG := 2;
          END_IF;
        END_IF;
      END_IF;

    ELSIF VMCURRENTOPCODE = 105 THEN
      (* OP_STOP (Z): VM 停止 *)
      VMSTATUS := 2;
      EXIT;

    ELSE
      (* 未知のオペコード: エラー *)
      VMSTATUS := 3;
      VMERROR := VMCURRENTOPCODE;
      EXIT;

    END_IF;
  ELSE
    (* どの組の担当でもない番号 *)
    VMSTATUS := 3;
    VMERROR := VMCURRENTOPCODE;
    EXIT;
  END_IF;

  (* バイトコード範囲チェック *)
  IF VMPC >= VMBYTECODELEN THEN
    VMSTATUS := 2;
    EXIT;
  END_IF;

END_FOR;

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