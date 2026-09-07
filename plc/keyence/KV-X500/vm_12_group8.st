// =======================================
// faRuby VM - オペコード 0x59 - 0x69
// =======================================
// 【自動生成】このファイルを直接編集しないでください。
//   定義: tools/opcode_table.rb
//   生成: tools/kvs_generator.rb  (rake vm_core)
//   編集した場合 test_kvs_generator.rb が失敗します。
//
// ラダーでの置き場所: 内側 FOR の中 (8 番目の群)
// 並び順と役割は vm_02_prologue.st の先頭にあります。

// 担当外の番号はここで素通りする。**判定はループの外に置く。**
// 見るのは上限だけ。89 未満は手前の群が実行して
// 65535 で潰しているので、ここには届かない
IF EM54:Z9 <= 105 THEN

  // 後ろの群がもう一度実行しないように潰す。**本体より先に置く。**
  // 本体は途中で BREAK することがあり、後ろに置くと通らない
  EM54:Z9 := 65535;

  // BREAK の相手 (1 回だけ回る)。抜けるとこのスクリプトが終わる
  FOR EM20:Z9 := 1 TO 1 DO

    IF EM6:Z9 = 95 THEN
      // OP_DEF (BB): メソッド表に symbols[b] = R[a+1] を登録
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      // シンボル表参照 (4ワード/エントリ)
      Z3 := EM8:Z9 * 4 + EM35:Z9;
      Z5 := FM0:Z3;   // メソッド番号
      Z7 := Z3 + 2;
      Z8 := FM0:Z7;   // 引数の数
      Z7 := Z3 + 3;
      Z4 := FM0:Z7;   // シンボル種別
      IF Z4 <> 2 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 3;
        EXIT;
      END_IF;
      Z3 := Z3 + 1;
      Z5 := FM0:Z3;   // ユーザー定義メソッドID
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
      Z3 := Z5 + 536 + Z9;
      EM0:Z3 := EM1:Z2;
      // OP_DEF の戻り値はメソッド名の Symbol。トップレベルでは捨てられる
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1.L:Z1 := EM8:Z9;
      EM0:Z1 := 6;

    ELSIF EM6:Z9 = 99 THEN
      // OP_TCLASS (B): R[a] = 定義先クラス (トップレベルは main)
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
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
