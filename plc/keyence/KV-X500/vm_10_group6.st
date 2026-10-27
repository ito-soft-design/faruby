// =======================================
// faRuby VM - オペコード 0x39 - 0x42
// =======================================
// 【自動生成】このファイルを直接編集しないでください。
//   定義: tools/opcode_table.rb
//   生成: tools/kvs_generator.rb  (rake vm_core)
//   編集した場合 test_kvs_generator.rb が失敗します。
//
// ラダーでの置き場所: 内側 FOR の中 (6 番目の群)
// 並び順と役割は vm_02_prologue.st の先頭にあります。

// 担当外の番号はここで素通りする。**判定はループの外に置く。**
// 見るのは上限だけ。57 未満は手前の群が実行して
// 65535 で潰しているので、ここには届かない
IF EM54:Z9 <= 66 THEN

  // 後ろの群がもう一度実行しないように潰す。**本体より先に置く。**
  // 本体は途中で BREAK することがあり、後ろに置くと通らない
  EM54:Z9 := 65535;

  // BREAK の相手 (1 回だけ回る)。抜けるとこのスクリプトが終わる
  FOR EM20:Z9 := 1 TO 1 DO

    IF EM6:Z9 = 58 THEN
      // OP_BREAK (B): 反復を打ち切って R[a] を返す
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      IF EM31:Z9 = 0 THEN
        // 反復の外での break
        EM1:Z9 := 3;
        EM2:Z9 := 9;
        EXIT;
      END_IF;
      Z3 := (EM31:Z9 - 1) * 10 + 392 + Z9;
      IF EM5:Z3 < 1 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 9;
        EXIT;
      END_IF;
      // break の値を R[0] へ。R[0] は呼んだ側の R[a] と同じ場所
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      Z2 := 0 + EM32:Z9 + Z9;
      EM1.L:Z2 := EM1.L:Z1;
      EM0:Z2 := EM0:Z1;
      EM31:Z9 := EM31:Z9 - 1;
      // 外した段がそのまま戻り先。減らした後なので top_frame_expr ではない
      Z3 := EM31:Z9 * 10 + 392 + Z9;
      EM0:Z9 := EM0:Z3;
      Z5 := EM1:Z3;
      EM32:Z9 := EM2:Z3;
      EM30:Z9 := Z5;
      // IREP テーブルから実行中の irep の情報を写す
      Z1 := Z5 * 8 + EM38:Z9;
      EM33:Z9 := ZF98304:Z1;
      EM10:Z9 := ZF98305:Z1;
      EM34:Z9 := ZF98306:Z1;
      EM35:Z9 := ZF98307:Z1;
      EM11:Z9 := ZF98308:Z1;

    ELSIF EM6:Z9 = 60 THEN
      // OP_ADD (B): R[a] = R[a] + R[a+1]
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      Z2 := (EM7:Z9 + 1) * 4 + EM32:Z9 + Z9;
      IF EM0:Z1 = 5 THEN
        IF EM0:Z2 = 5 THEN
          EM1.F:Z1 := EM1.F:Z1 + EM1.F:Z2;
          EM0:Z1 := 5;
        ELSE
          EM1.F:Z1 := EM1.F:Z1 + EM1.L:Z2;
          EM0:Z1 := 5;
        END_IF;
      ELSE
        IF EM0:Z2 = 5 THEN
          EM1.F:Z1 := EM1.L:Z1 + EM1.F:Z2;
          EM0:Z1 := 5;
        ELSE
          IF EM0:Z1 = 7 THEN
            // プールの空きスロットを取る。返さないので使い切ったら止まる
            IF EM39:Z9 >= 32 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 10;
              EXIT;
            END_IF;
            Z4 := EM1.L:Z1;
            Z4 := Z4 * 52 + 1816 + Z9;
            EM16.L:Z9 := EM0:Z4;
            Z5 := EM1.L:Z2;
            Z5 := Z5 * 52 + 1816 + Z9;
            EM18.L:Z9 := EM0:Z5;
            // 1 スロットに収まること
            Z6 := EM16.L:Z9 + EM18.L:Z9;
            IF Z6 > 96 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 10;
              EXIT;
            END_IF;
            // 新しいスロットへ左側をワード単位で写す。並びが同じなのでそのまま
            Z3 := EM39:Z9 * 52 + 1816 + Z9;
            EM0:Z3 := EM16.L:Z9;
            EM45:Z9 := EM16.L:Z9 + 1;
            EM45:Z9 := EM45:Z9 / 2;
            IF EM45:Z9 > 0 THEN
              EM45:Z9 := EM45:Z9 - 1;
              FOR EM42:Z9 := 0 TO EM45:Z9 DO
                Z7 := EM42:Z9 + Z4 + 4;
                Z8 := EM42:Z9 + Z3 + 4;
                EM0:Z8 := EM0:Z7;
              END_FOR;
            END_IF;
            // 右側を継ぎ足す。Z4 を継ぎ足す元にする
            Z4 := Z5;
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
            EM1.L:Z1 := EM39:Z9;   // スロット番号
            EM0:Z1 := 7;
            EM39:Z9 := EM39:Z9 + 1;
          ELSE
            EM1.L:Z1 := EM1.L:Z1 + EM1.L:Z2;
            EM0:Z1 := 4;
          END_IF;
        END_IF;
      END_IF;

    ELSIF EM6:Z9 = 61 THEN
      // OP_ADDI (BB): R[a] = R[a] + b
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      IF EM0:Z1 = 5 THEN
        EM1.F:Z1 := EM1.F:Z1 + EM8:Z9;
        EM0:Z1 := 5;
      ELSE
        EM1.L:Z1 := EM1.L:Z1 + EM8:Z9;
        EM0:Z1 := 4;
      END_IF;

    ELSIF EM6:Z9 = 62 THEN
      // OP_SUB (B): R[a] = R[a] - R[a+1]
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      Z2 := (EM7:Z9 + 1) * 4 + EM32:Z9 + Z9;
      IF EM0:Z1 = 5 THEN
        IF EM0:Z2 = 5 THEN
          EM1.F:Z1 := EM1.F:Z1 - EM1.F:Z2;
          EM0:Z1 := 5;
        ELSE
          EM1.F:Z1 := EM1.F:Z1 - EM1.L:Z2;
          EM0:Z1 := 5;
        END_IF;
      ELSE
        IF EM0:Z2 = 5 THEN
          EM1.F:Z1 := EM1.L:Z1 - EM1.F:Z2;
          EM0:Z1 := 5;
        ELSE
          EM1.L:Z1 := EM1.L:Z1 - EM1.L:Z2;
          EM0:Z1 := 4;
        END_IF;
      END_IF;

    ELSIF EM6:Z9 = 63 THEN
      // OP_SUBI (BB): R[a] = R[a] - b
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      IF EM0:Z1 = 5 THEN
        EM1.F:Z1 := EM1.F:Z1 - EM8:Z9;
        EM0:Z1 := 5;
      ELSE
        EM1.L:Z1 := EM1.L:Z1 - EM8:Z9;
        EM0:Z1 := 4;
      END_IF;

    ELSIF EM6:Z9 = 64 THEN
      // OP_MUL (B): R[a] = R[a] * R[a+1]
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      Z2 := (EM7:Z9 + 1) * 4 + EM32:Z9 + Z9;
      IF EM0:Z1 = 5 THEN
        IF EM0:Z2 = 5 THEN
          EM1.F:Z1 := EM1.F:Z1 * EM1.F:Z2;
          EM0:Z1 := 5;
        ELSE
          EM1.F:Z1 := EM1.F:Z1 * EM1.L:Z2;
          EM0:Z1 := 5;
        END_IF;
      ELSE
        IF EM0:Z2 = 5 THEN
          EM1.F:Z1 := EM1.L:Z1 * EM1.F:Z2;
          EM0:Z1 := 5;
        ELSE
          EM1.L:Z1 := EM1.L:Z1 * EM1.L:Z2;
          EM0:Z1 := 4;
        END_IF;
      END_IF;

    ELSIF EM6:Z9 = 65 THEN
      // OP_DIV (B): R[a] = R[a] / R[a+1]
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      Z2 := (EM7:Z9 + 1) * 4 + EM32:Z9 + Z9;
      IF EM0:Z1 = 5 THEN
        IF EM0:Z2 = 5 THEN
          IF EM1.F:Z2 <> 0 THEN
            EM1.F:Z1 := EM1.F:Z1 / EM1.F:Z2;
          ELSE
            // 0 除算。KV の / は CR2012 を出すため実行せず、
            // IEEE754 の無限大 / 非数のビット列を直接置く
            // 代入先は被除数と同じレジスタなので、先に符号から上位ワードを決める。
            // 被除数を書き換えてから符号を見ると、低位ワードを消した時点で
            // 整数の 1-65535 が 0 になり、+Infinity が NaN になる
            EM16:Z9 := 32704;   // 既定は NaN (0.0 / 0.0)
            IF EM1.F:Z1 > 0 THEN
              EM16:Z9 := 32640;   // +Infinity
            END_IF;
            IF EM1.F:Z1 < 0 THEN
              EM16:Z9 := 65408;   // -Infinity
            END_IF;
            EM1:Z1 := 0;
            EM2:Z1 := EM16:Z9;
          END_IF;
          EM0:Z1 := 5;
        ELSE
          IF EM1.L:Z2 <> 0 THEN
            EM1.F:Z1 := EM1.F:Z1 / EM1.L:Z2;
          ELSE
            // 0 除算。KV の / は CR2012 を出すため実行せず、
            // IEEE754 の無限大 / 非数のビット列を直接置く
            // 代入先は被除数と同じレジスタなので、先に符号から上位ワードを決める。
            // 被除数を書き換えてから符号を見ると、低位ワードを消した時点で
            // 整数の 1-65535 が 0 になり、+Infinity が NaN になる
            EM16:Z9 := 32704;   // 既定は NaN (0.0 / 0.0)
            IF EM1.F:Z1 > 0 THEN
              EM16:Z9 := 32640;   // +Infinity
            END_IF;
            IF EM1.F:Z1 < 0 THEN
              EM16:Z9 := 65408;   // -Infinity
            END_IF;
            EM1:Z1 := 0;
            EM2:Z1 := EM16:Z9;
          END_IF;
          EM0:Z1 := 5;
        END_IF;
      ELSE
        IF EM0:Z2 = 5 THEN
          IF EM1.F:Z2 <> 0 THEN
            EM1.F:Z1 := EM1.L:Z1 / EM1.F:Z2;
          ELSE
            // 0 除算。KV の / は CR2012 を出すため実行せず、
            // IEEE754 の無限大 / 非数のビット列を直接置く
            // 代入先は被除数と同じレジスタなので、先に符号から上位ワードを決める。
            // 被除数を書き換えてから符号を見ると、低位ワードを消した時点で
            // 整数の 1-65535 が 0 になり、+Infinity が NaN になる
            EM16:Z9 := 32704;   // 既定は NaN (0.0 / 0.0)
            IF EM1.L:Z1 > 0 THEN
              EM16:Z9 := 32640;   // +Infinity
            END_IF;
            IF EM1.L:Z1 < 0 THEN
              EM16:Z9 := 65408;   // -Infinity
            END_IF;
            EM1:Z1 := 0;
            EM2:Z1 := EM16:Z9;
          END_IF;
          EM0:Z1 := 5;
        ELSE
          IF EM1.L:Z2 <> 0 THEN
            // Ruby の整数除算は切り下げ。KV の / は0方向へ切り捨てるため補正する
            EM16.L:Z9 := EM1.L:Z1;   // 被除数を退避
            EM1.L:Z1 := EM1.L:Z1 / EM1.L:Z2;
            EM18.L:Z9 := EM16.L:Z9 - EM1.L:Z1 * EM1.L:Z2;   // 余り
            IF EM18.L:Z9 <> 0 THEN
              // 符号が異なるときだけ切り下げになる
              IF EM16.L:Z9 < 0 THEN
                IF EM1.L:Z2 > 0 THEN
                  EM1.L:Z1 := EM1.L:Z1 - 1;
                END_IF;
              ELSE
                IF EM1.L:Z2 < 0 THEN
                  EM1.L:Z1 := EM1.L:Z1 - 1;
                END_IF;
              END_IF;
            END_IF;
            EM0:Z1 := 4;
          ELSE
            EM1:Z9 := 3;
            EM2:Z9 := 1;
            EXIT;
          END_IF;
        END_IF;
      END_IF;

    ELSIF EM6:Z9 = 66 THEN
      // OP_EQ (B): R[a] = (R[a] == R[a+1]) ? true : false
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := ZF98304:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      Z2 := (EM7:Z9 + 1) * 4 + EM32:Z9 + Z9;
      // 数値は型が違っても値で比べる (Ruby では 1 == 1.0 は真)
      // 数値以外は型と値の両方が一致したときだけ真 (nil == false は偽)
      // 結果を R[a] に書くと比較元が壊れるため、先に判定してから代入する
      EM16:Z9 := 0;
      // シンボルや配列のタグは 4 より大きいので、上限も見ないと
      // 番号やスロット番号が数値として比べられてしまう
      Z3 := 0;
      IF EM0:Z1 >= 4 THEN
        IF EM0:Z1 <= 5 THEN
          Z3 := 1;
        END_IF;
      END_IF;
      Z4 := 0;
      IF EM0:Z2 >= 4 THEN
        IF EM0:Z2 <= 5 THEN
          Z4 := 1;
        END_IF;
      END_IF;
      IF Z3 = 1 THEN
        IF Z4 = 1 THEN
          IF EM0:Z1 = 5 THEN
            IF EM0:Z2 = 5 THEN
              IF EM1.F:Z1 = EM1.F:Z2 THEN
                EM16:Z9 := 1;
              END_IF;
            ELSE
              IF EM1.F:Z1 = EM1.L:Z2 THEN
                EM16:Z9 := 1;
              END_IF;
            END_IF;
          ELSE
            IF EM0:Z2 = 5 THEN
              IF EM1.L:Z1 = EM1.F:Z2 THEN
                EM16:Z9 := 1;
              END_IF;
            ELSE
              IF EM1.L:Z1 = EM1.L:Z2 THEN
                EM16:Z9 := 1;
              END_IF;
            END_IF;
          END_IF;
        ELSE
          // 数値と非数値は等しくない
        END_IF;
      ELSE
        IF EM0:Z1 = EM0:Z2 THEN
          IF EM0:Z1 = 7 THEN
            // 文字列は中身で比べる。スロット番号ではない
            // Z3 を借りる。返すまでの間に呼ぶ側の値を壊さないため
            EM46:Z9 := Z3;
            EM43:Z9 := 0;
            Z3 := EM1.L:Z1;
            Z3 := Z3 * 52 + 1816 + Z9;
            EM44:Z9 := EM0:Z3;   // バイト数
            Z3 := EM1.L:Z2;
            Z3 := Z3 * 52 + 1816 + Z9;
            IF EM44:Z9 = EM0:Z3 THEN
              // バイト数が同じ。ここから中身を見る
              EM43:Z9 := 1;
              EM45:Z9 := EM44:Z9 + 1;
              EM45:Z9 := EM45:Z9 / 2;   // ワード数
              IF EM45:Z9 > 0 THEN
                EM45:Z9 := EM45:Z9 - 1;
                FOR EM42:Z9 := 0 TO EM45:Z9 DO
                  Z3 := EM1.L:Z1;
                  Z3 := Z3 * 52 + 1816 + Z9;
                  Z3 := EM42:Z9 + Z3 + 4;
                  EM44:Z9 := EM0:Z3;
                  Z3 := EM1.L:Z2;
                  Z3 := Z3 * 52 + 1816 + Z9;
                  Z3 := EM42:Z9 + Z3 + 4;
                  IF EM44:Z9 <> EM0:Z3 THEN
                    EM43:Z9 := 0;
                  END_IF;
                END_FOR;
              END_IF;
            END_IF;
            // 借りた Z3 を返す
            Z3 := EM46:Z9;
            IF EM43:Z9 = 1 THEN
              EM16:Z9 := 1;
            END_IF;
          ELSE
            IF EM1.L:Z1 = EM1.L:Z2 THEN
              EM16:Z9 := 1;
            END_IF;
          END_IF;
        END_IF;
      END_IF;
      IF EM16:Z9 = 1 THEN
        EM1.L:Z1 := 1;
        EM0:Z1 := 3;
      ELSE
        EM1.L:Z1 := 0;
        EM0:Z1 := 2;
      END_IF;

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
