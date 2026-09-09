// =======================================
// faRuby VM - オペコード 0x46 - 0x58
// =======================================
// 【自動生成】このファイルを直接編集しないでください。
//   定義: tools/opcode_table.rb
//   生成: tools/kvs_generator.rb  (rake vm_core)
//   編集した場合 test_kvs_generator.rb が失敗します。
//
// ラダーでの置き場所: 内側 FOR の中 (7 番目の群)
// 並び順と役割は vm_02_prologue.st の先頭にあります。

// 担当外の番号はここで素通りする。**判定はループの外に置く。**
// 見るのは上限だけ。70 未満は手前の群が実行して
// 65535 で潰しているので、ここには届かない
IF EM54:Z9 <= 88 THEN

  // 後ろの群がもう一度実行しないように潰す。**本体より先に置く。**
  // 本体は途中で BREAK することがあり、後ろに置くと通らない
  EM54:Z9 := 65535;

  // BREAK の相手 (1 回だけ回る)。抜けるとこのスクリプトが終わる
  FOR EM20:Z9 := 1 TO 1 DO

    IF EM6:Z9 = 70 THEN
      // OP_GE (B): R[a] = (R[a] >= R[a+1]) ? true : false
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      Z2 := (EM7:Z9 + 1) * 4 + EM32:Z9 + Z9;
      IF EM0:Z1 = 5 THEN
        IF EM0:Z2 = 5 THEN
          IF EM1.F:Z1 >= EM1.F:Z2 THEN
            EM1.L:Z1 := 1;
            EM0:Z1 := 3;
          ELSE
            EM1.L:Z1 := 0;
            EM0:Z1 := 2;
          END_IF;
        ELSE
          IF EM1.F:Z1 >= EM1.L:Z2 THEN
            EM1.L:Z1 := 1;
            EM0:Z1 := 3;
          ELSE
            EM1.L:Z1 := 0;
            EM0:Z1 := 2;
          END_IF;
        END_IF;
      ELSE
        IF EM0:Z2 = 5 THEN
          IF EM1.L:Z1 >= EM1.F:Z2 THEN
            EM1.L:Z1 := 1;
            EM0:Z1 := 3;
          ELSE
            EM1.L:Z1 := 0;
            EM0:Z1 := 2;
          END_IF;
        ELSE
          IF EM1.L:Z1 >= EM1.L:Z2 THEN
            EM1.L:Z1 := 1;
            EM0:Z1 := 3;
          ELSE
            EM1.L:Z1 := 0;
            EM0:Z1 := 2;
          END_IF;
        END_IF;
      END_IF;

    ELSIF EM6:Z9 = 71 THEN
      // OP_ARRAY (BB): R[a] = [R[a] .. R[a+b-1]]
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      // プールの空きスロットを取る。返さないので使い切ったら止まる
      IF EM39:Z9 >= 16 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 10;
        EXIT;
      END_IF;
      IF EM8:Z9 > 12 THEN
        // 1 スロットの容量を超える要素数
        EM1:Z9 := 3;
        EM2:Z9 := 10;
        EXIT;
      END_IF;
      // スロットの見出し
      Z2 := EM39:Z9 * 52 + 1000 + Z9;
      EM0:Z2 := EM8:Z9;
      // 要素を写す。要素数 0 (空配列) では引き算もしない
      // EM は16ビット符号なしのため、0 - 1 は 65535 になり得る
      IF EM8:Z9 > 0 THEN
        Z3 := EM8:Z9 - 1;
        FOR Z4 := 0 TO Z3 DO
          Z5 := (EM7:Z9 + Z4) * 4 + EM32:Z9 + Z9;
          Z6 := Z4 * 4 + Z2 + 4;
          EM1.L:Z6 := EM1.L:Z5;
          EM0:Z6 := EM0:Z5;
        END_FOR;
      END_IF;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1.L:Z1 := EM39:Z9;   // スロット番号
      EM0:Z1 := 8;
      EM39:Z9 := EM39:Z9 + 1;

    ELSIF EM6:Z9 = 72 THEN
      // OP_ARRAY2 (BBB): R[a] = [R[b] .. R[b+c-1]]
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM9:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      // プールの空きスロットを取る。返さないので使い切ったら止まる
      IF EM39:Z9 >= 16 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 10;
        EXIT;
      END_IF;
      IF EM9:Z9 > 12 THEN
        // 1 スロットの容量を超える要素数
        EM1:Z9 := 3;
        EM2:Z9 := 10;
        EXIT;
      END_IF;
      // スロットの見出し
      Z2 := EM39:Z9 * 52 + 1000 + Z9;
      EM0:Z2 := EM9:Z9;
      // 要素を写す。要素数 0 (空配列) では引き算もしない
      // EM は16ビット符号なしのため、0 - 1 は 65535 になり得る
      IF EM9:Z9 > 0 THEN
        Z3 := EM9:Z9 - 1;
        FOR Z4 := 0 TO Z3 DO
          Z5 := (EM8:Z9 + Z4) * 4 + EM32:Z9 + Z9;
          Z6 := Z4 * 4 + Z2 + 4;
          EM1.L:Z6 := EM1.L:Z5;
          EM0:Z6 := EM0:Z5;
        END_FOR;
      END_IF;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1.L:Z1 := EM39:Z9;   // スロット番号
      EM0:Z1 := 8;
      EM39:Z9 := EM39:Z9 + 1;

    ELSIF EM6:Z9 = 81 THEN
      // OP_STRING (BB): R[a] = pool[b] の複製 (文字列)
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z2 := EM8:Z9 * 4 + EM34:Z9;
      // 文字列は値スロットに入らない。位置とバイト数だけが入っている
      Z3 := FM1:Z2;   // 文字列領域の位置 (ワード)
      Z4 := FM2:Z2;   // バイト数
      // プールの空きスロットを取る。返さないので使い切ったら止まる
      IF EM39:Z9 >= 16 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 10;
        EXIT;
      END_IF;
      IF Z4 > 96 THEN
        // 1 スロットに収まらない (ホストでも見ているが念のため)
        EM1:Z9 := 3;
        EM2:Z9 := 10;
        EXIT;
      END_IF;
      // スロットの見出しはバイト数
      Z5 := EM39:Z9 * 52 + 1000 + Z9;
      EM0:Z5 := Z4;
      // ワード単位で写す。並びが同じなので詰め替えは要らない
      // 奇数バイトのときは最後のワードの下位バイトが 0 になる
      Z6 := (Z4 + 1) / 2;   // ワード数
      IF Z6 > 0 THEN
        Z6 := Z6 - 1;
        FOR Z7 := 0 TO Z6 DO
          Z8 := Z7 + Z3 + EM38:Z9 + 4128;
          Z2 := Z7 + Z5 + 4;
          EM0:Z2 := FM0:Z8;
        END_FOR;
      END_IF;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1.L:Z1 := EM39:Z9;   // スロット番号
      EM0:Z1 := 7;
      EM39:Z9 := EM39:Z9 + 1;

    ELSIF EM6:Z9 = 82 THEN
      // OP_STRCAT (B): R[a] = R[a] + R[a+1] (文字列を継ぎ足す)
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      Z2 := (EM7:Z9 + 1) * 4 + EM32:Z9 + Z9;
      IF EM0:Z1 <> 7 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 4;
        EXIT;
      END_IF;
      IF EM0:Z2 <> 7 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 4;
        EXIT;
      END_IF;
      Z3 := EM1.L:Z1;
      Z3 := Z3 * 52 + 1000 + Z9;
      Z4 := EM1.L:Z2;
      Z4 := Z4 * 52 + 1000 + Z9;
      EM16.L:Z9 := EM0:Z3;
      EM18.L:Z9 := EM0:Z4;
      // 1 スロットに収まること
      Z5 := EM16.L:Z9 + EM18.L:Z9;
      IF Z5 > 96 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 10;
        EXIT;
      END_IF;
      IF EM18.L:Z9 > 0 THEN
        Z6 := EM18.L:Z9;
        Z6 := Z6 - 1;
        FOR Z5 := 0 TO Z6 DO
          // 継ぎ足す元のバイトを 1 つ取り出す
          Z7 := Z5 / 2;
          Z8 := Z7 + Z4 + 4;
          Z8 := EM0:Z8;
          Z7 := Z7 * 2;
          IF Z5 = Z7 THEN
            // 偶数の位置は上位バイト
            Z8 := Z8 / 256;
          ELSE
            // 奇数の位置は下位バイト
            Z7 := Z8 / 256;
            Z8 := Z8 - Z7 * 256;
          END_IF;
          // 書き先の位置 (継ぎ足す先の長さ + 何バイト目か)
          EM44:Z9 := EM16.L:Z9 + Z5;
          Z7 := EM44:Z9;
          Z7 := Z7 / 2;
          Z7 := Z7 + Z3 + 4;
          EM45:Z9 := EM44:Z9 / 2;
          EM45:Z9 := EM45:Z9 * 2;
          IF EM44:Z9 = EM45:Z9 THEN
            // 偶数。下位バイトは 0 にしておく (次のバイトか詰め物が入る)
            EM0:Z7 := Z8 * 256;
          ELSE
            // 奇数。上位バイトを残して下位に入れる
            EM45:Z9 := EM0:Z7;
            EM45:Z9 := EM45:Z9 / 256;
            EM0:Z7 := EM45:Z9 * 256 + Z8;
          END_IF;
        END_FOR;
      END_IF;
      // 長さを更新する
      EM16.L:Z9 := EM16.L:Z9 + EM18.L:Z9;
      EM0:Z3 := EM16.L:Z9;

    ELSIF EM6:Z9 = 83 THEN
      // OP_HASH (BB): R[a] = { R[a] => R[a+1], .. } (b 組)
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      // ハッシュは配列 2 本。空きスロットが 2 つ要る
      Z2 := EM39:Z9 + 1;
      IF Z2 >= 16 THEN
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
      Z2 := EM39:Z9 * 52 + 1000 + Z9;
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
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      // 実行中の irep の最初の子の番号に、親から見た子の番号を足す
      Z3 := EM30:Z9 * 8 + EM38:Z9;
      Z4 := Z3 + 5;
      EM16:Z9 := FM0:Z4 + EM8:Z9;
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
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      // 実行中の irep の最初の子の番号に、親から見た子の番号を足す
      Z3 := EM30:Z9 * 8 + EM38:Z9;
      Z4 := Z3 + 5;
      EM16:Z9 := FM0:Z4 + EM8:Z9;
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
