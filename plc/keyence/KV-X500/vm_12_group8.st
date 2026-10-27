// =======================================
// faRuby VM - オペコード 0x53 - 0x69
// =======================================
// 【自動生成】このファイルを直接編集しないでください。
//   定義: tools/opcode_table.rb
//   生成: tools/kvs_generator.rb  (rake vm_core)
//   編集した場合 test_kvs_generator.rb が失敗します。
//
// ラダーでの置き場所: 内側 FOR の中 (8 番目の群)
// 並び順と役割は vm_02_prologue.st の先頭にあります。

// 担当外の番号はここで素通りする。**判定はループの外に置く。**
// 見るのは上限だけ。83 未満は手前の群が実行して
// 65535 で潰しているので、ここには届かない
IF EM54:Z9 <= 105 THEN

  // 後ろの群がもう一度実行しないように潰す。**本体より先に置く。**
  // 本体は途中で BREAK することがあり、後ろに置くと通らない
  EM54:Z9 := 65535;

  // BREAK の相手 (1 回だけ回る)。抜けるとこのスクリプトが終わる
  FOR EM20:Z9 := 1 TO 1 DO

    IF EM6:Z9 = 83 THEN
      // OP_HASH (BB): R[a] = { R[a] => R[a+1], .. } (b 組)
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      // ハッシュは配列 2 本。空きスロットが 2 つ要る
      Z2 := EM39:Z9 + 1;
      IF Z2 >= 32 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 10;
        EXIT;
      END_IF;
      IF EM8:Z9 > 12 THEN
        // 1 スロットの容量を超える組の数
        EM1:Z9 := 3;
        EM2:Z9 := 10;
        EXIT;
      END_IF;
      // 鍵の配列と値の配列の見出し
      Z2 := EM39:Z9 * 52 + 1816 + Z9;
      Z3 := Z2 + 52;
      EM0:Z2 := EM8:Z9;
      EM0:Z3 := EM8:Z9;
      // 組を写す。組の数 0 (空ハッシュ) では引き算もしない
      IF EM8:Z9 > 0 THEN
        Z4 := EM8:Z9 - 1;
        FOR Z5 := 0 TO Z4 DO
          Z6 := (EM7:Z9 + Z5 * 2) * 4 + EM32:Z9 + Z9;   // 鍵
          Z7 := Z5 * 4 + Z2 + 4;
          EM1.L:Z7 := EM1.L:Z6;
          EM0:Z7 := EM0:Z6;
          Z6 := (EM7:Z9 + Z5 * 2 + 1) * 4 + EM32:Z9 + Z9;   // 値
          Z7 := Z5 * 4 + Z3 + 4;
          EM1.L:Z7 := EM1.L:Z6;
          EM0:Z7 := EM0:Z6;
        END_FOR;
      END_IF;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1:Z1 := EM39:Z9;   // 鍵の配列
      Z2 := EM39:Z9 + 1;
      EM2:Z1 := Z2;   // 値の配列
      EM0:Z1 := 9;
      EM39:Z9 := Z2 + 1;

    ELSIF EM6:Z9 = 87 THEN
      // OP_BLOCK (BB): R[a] = 子 irep b から作ったブロック
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
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1:Z1 := EM16:Z9;   // 本体の irep
      Z4 := 65535;
      IF EM31:Z9 > 0 THEN
        Z4 := EM31:Z9 - 1;
      END_IF;
      EM2:Z1 := Z4;   // 定義元のフレーム
      EM0:Z1 := 12;

    ELSIF EM6:Z9 = 88 THEN
      // OP_METHOD (BB): R[a] = 子 irep b への参照
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
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1:Z1 := EM16:Z9;   // 本体の irep
      EM2:Z1 := 65535;   // メソッドは外側を見ない
      EM0:Z1 := 12;

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
      // メソッド表 (ID => 本体の irep 番号)
      Z3 := Z5 + 552 + Z9;
      EM0:Z3 := EM1:Z2;
      // OP_DEF の戻り値はメソッド名の Symbol。トップレベルでは捨てられる
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1.L:Z1 := EM8:Z9;
      EM0:Z1 := 6;

    ELSIF EM6:Z9 = 99 THEN
      // OP_TCLASS (B): R[a] = 定義先クラス (トップレベルは main)
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1.L:Z1 := 0;
      EM0:Z1 := 10;

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
