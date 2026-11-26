// =======================================
// faRuby VM - オペコード 0x5D - 0x69
// =======================================
// 【自動生成】このファイルを直接編集しないでください。
//   定義: tools/opcode_table.rb
//   生成: tools/kvs_generator.rb  (rake vm_core)
//   編集した場合 test_kvs_generator.rb が失敗します。
//
// ラダーでの置き場所: 内側 FOR の中 (8 番目の群)
// 並び順と役割は vm_02_prologue.st の先頭にあります。

// 担当外の番号はここで素通りする。**判定はループの外に置く。**
// 見るのは上限だけ。93 未満は手前の群が実行して
// 65535 で潰しているので、ここには届かない
IF EM54:Z9 <= 105 THEN

  // 後ろの群がもう一度実行しないように潰す。**本体より先に置く。**
  // 本体は途中で BREAK することがあり、後ろに置くと通らない
  EM54:Z9 := 65535;

  // BREAK の相手 (1 回だけ回る)。抜けるとこのスクリプトが終わる
  FOR EM20:Z9 := 1 TO 1 DO

    IF EM6:Z9 = 94 THEN
      // OP_EXEC (BB): クラス本体 (子 irep b) を R[a] を self として実行
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      // 実行中の irep の最初の子の番号に、親から見た子の番号を足す
      Z3 := EM30:Z9 * 8 + EM38:Z9;
      Z4 := Z3 + 5;
      EM16:Z9 := ZF98304:Z4 + EM8:Z9;
      IF EM16:Z9 >= EM36:Z9 THEN
        // 指す先の irep が無い
        EM1:Z9 := 3;
        EM2:Z9 := 7;
        EXIT;
      END_IF;
      Z5 := EM16:Z9;   // クラス本体の irep
      IF EM31:Z9 >= 16 THEN
        // 呼び出しが深すぎる。PLC はメモリ固定なので上限で止めるしかない
        EM1:Z9 := 3;
        EM2:Z9 := 5;
        EXIT;
      END_IF;
      // 戻り先を積む
      Z3 := EM31:Z9 * 10 + 392 + Z9;
      EM0:Z3 := EM0:Z9;
      EM1:Z3 := EM30:Z9;
      EM2:Z3 := EM32:Z9;
      EM4:Z3 := 65535;
      EM5:Z3 := 0;
      // レジスタ窓をずらす。呼ばれた側の R[0] が呼んだ側の R[a]
      EM32:Z9 := EM32:Z9 + EM7:Z9 * 4;
      EM3:Z3 := EM32:Z9;   // このフレームの窓 (OP_GETUPVAR が見る)
      EM31:Z9 := EM31:Z9 + 1;
      EM37:Z9 := 0;
      EM30:Z9 := Z5;
      // IREP テーブルから実行中の irep の情報を写す
      Z1 := Z5 * 8 + EM38:Z9;
      EM33:Z9 := ZF98304:Z1;
      EM10:Z9 := ZF98305:Z1;
      EM34:Z9 := ZF98306:Z1;
      EM35:Z9 := ZF98307:Z1;
      EM11:Z9 := ZF98308:Z1;
      // レジスタ窓が領域からはみ出さないこと
      EM16:Z9 := EM32:Z9 + EM11:Z9 * 4;
      IF EM16:Z9 > 392 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 5;
        EXIT;
      END_IF;
      EM0:Z9 := 0;

    ELSIF EM6:Z9 = 95 THEN
      // OP_DEF (BB): メソッド表に symbols[b] = R[a+1] を登録
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      // シンボル表参照 (4ワード/エントリ)
      Z3 := EM8:Z9 * 4 + EM35:Z9;
      Z5 := ZF98304:Z3;   // メソッド番号
      Z7 := Z3 + 2;
      Z8 := ZF98304:Z7;   // 引数の数
      Z7 := Z3 + 3;
      Z4 := ZF98304:Z7;   // シンボル種別
      IF Z4 <> 2 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 3;
        EXIT;
      END_IF;
      Z3 := Z3 + 1;
      Z5 := ZF98304:Z3;   // ユーザー定義メソッドID
      IF Z5 = 0 THEN
        // 組み込みと同じ名前は再定義できない
        EM1:Z9 := 3;
        EM2:Z9 := 3;
        EXIT;
      END_IF;
      Z2 := (EM7:Z9 + 1) * 4 + EM32:Z9 + Z9;
      IF EM0:Z2 <> 12 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 3;
        EXIT;
      END_IF;
      // メソッド表 (クラス × 名前 => 本体の irep 番号)
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      // 探索の行。レシーバのクラス (main は 0 行目)
      Z6 := 0;
      IF EM0:Z1 = 13 THEN
        Z6 := EM1:Z1;
      END_IF;
      IF EM0:Z1 = 10 THEN
        // オブジェクトは見出しのクラス番号。値は スロット + 1 (0 は main)
        IF EM1:Z1 <> 0 THEN
          Z6 := (EM1:Z1 - 1) * 52 + 2008 + Z9;
          Z6 := EM0:Z6;
        END_IF;
      END_IF;
      Z6 := Z6 * 32;
      Z3 := Z6 + Z5 + 552 + Z9;
      EM0:Z3 := EM1:Z2;
      // OP_DEF の戻り値はメソッド名の Symbol。トップレベルでは捨てられる
      EM1.L:Z1 := EM8:Z9;
      EM0:Z1 := 6;

    ELSIF EM6:Z9 = 99 THEN
      // OP_TCLASS (B): R[a] = 定義先クラス (self。トップレベルは main)
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      // 定義先は self。クラス本体ではそのクラス、トップレベルでは main
      Z3 := 0 + EM32:Z9 + Z9;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1.L:Z1 := EM1.L:Z3;
      EM0:Z1 := EM0:Z3;

    ELSIF EM6:Z9 = 105 THEN
      // OP_STOP (Z): VM 停止
      EM1:Z9 := 2;
      EXIT;

    ELSE
      // 未知のオペコード: エラー
      EM1:Z9 := 3;
      EM2:Z9 := EM6:Z9;
      EXIT;

    END_IF;

    // バイトコード範囲チェック
    IF EM0:Z9 >= EM10:Z9 THEN
      EM1:Z9 := 2;
      EXIT;
    END_IF;

  END_FOR;
END_IF;
