// =======================================
// faRuby VM - オペコード 0x29 - 0x3D
// =======================================
// 【自動生成】このファイルを直接編集しないでください。
//   定義: tools/opcode_table.rb
//   生成: tools/kvs_generator.rb  (rake vm_core)
//   編集した場合 test_kvs_generator.rb が失敗します。
//
// ラダーでの置き場所: 内側 FOR の中 (5 番目の群)
// 並び順と役割は vm_02_prologue.st の先頭にあります。

// 担当外の番号はここで素通りする。**判定はループの外に置く。**
// 見るのは上限だけ。41 未満は手前の群が実行して
// 65535 で潰しているので、ここには届かない
IF EM54:Z9 <= 61 THEN

  // 後ろの群がもう一度実行しないように潰す。**本体より先に置く。**
  // 本体は途中で BREAK することがあり、後ろに置くと通らない
  EM54:Z9 := 65535;

  // BREAK の相手 (1 回だけ回る)。抜けるとこのスクリプトが終わる
  FOR EM20:Z9 := 1 TO 1 DO

    IF EM6:Z9 = 47 THEN
      // OP_SEND (BBB): R[a] = R[a].symbols[b](R[a+1]..)
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM9:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      // シンボル表参照 (4ワード/エントリ)
      Z3 := EM8:Z9 * 4 + EM35:Z9;
      Z5 := FM0:Z3;   // メソッド番号
      Z7 := Z3 + 2;
      Z8 := FM0:Z7;   // 引数の数
      Z7 := Z3 + 3;
      Z4 := FM0:Z7;   // シンボル種別
      IF Z4 <> 2 THEN
        // メソッド名でないシンボルへの呼び出し
        EM1:Z9 := 3;
        EM2:Z9 := 3;
        EXIT;
      END_IF;
      Z3 := Z3 + 1;
      Z6 := FM0:Z3;   // ユーザー定義メソッドID
      IF Z5 <> 0 THEN
        // 組み込みメソッド。フレームを積まずその場で計算する
        IF EM9:Z9 <> Z8 THEN
          // 引数の数が定義と違う
          // オペランドは位置引数とキーワード引数の数を4ビットずつ詰めたもの。
          // 普通の呼び出しでは引数の数と一致し、スプラットやキーワード付きは弾かれる
          EM1:Z9 := 3;
          EM2:Z9 := 3;
          EXIT;
        END_IF;
        Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
        Z2 := (EM7:Z9 + 1) * 4 + EM32:Z9 + Z9;
        // メソッド番号の区分ごとにレシーバのタグの範囲を見る (METHOD_RECEIVER_GROUPS)
        // 3 未満 (!= と !) はどの型でも呼べる
        IF Z5 >= 3 THEN
          IF Z5 <= 17 THEN
            // 数値 (タグ 4-5)
            IF EM0:Z1 < 4 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
            IF EM0:Z1 > 5 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
          ELSIF Z5 <= 19 THEN
            // 文字列・配列・ハッシュ (タグ 7-9)
            IF EM0:Z1 < 7 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
            IF EM0:Z1 > 9 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
          ELSIF Z5 <= 20 THEN
            // 整数・文字列・配列 (タグ 4-8)
            IF EM0:Z1 < 4 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
            IF EM0:Z1 > 8 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
          ELSIF Z5 <= 21 THEN
            // 配列・ハッシュ (タグ 8-9)
            IF EM0:Z1 < 8 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
            IF EM0:Z1 > 9 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
          ELSIF Z5 <= 22 THEN
            // 配列 (タグ 8)
            IF EM0:Z1 <> 8 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
          ELSIF Z5 <= 25 THEN
            // ハッシュ (タグ 9)
            IF EM0:Z1 <> 9 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
          ELSE
            // デバイス参照 (タグ 11)
            IF EM0:Z1 <> 11 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
          END_IF;
        END_IF;
        IF Z5 = 1 THEN
          // !=
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
                Z3 := Z3 * 52 + 1000 + Z9;
                EM44:Z9 := EM0:Z3;   // バイト数
                Z3 := EM1.L:Z2;
                Z3 := Z3 * 52 + 1000 + Z9;
                IF EM44:Z9 = EM0:Z3 THEN
                  // バイト数が同じ。ここから中身を見る
                  EM43:Z9 := 1;
                  EM45:Z9 := EM44:Z9 + 1;
                  EM45:Z9 := EM45:Z9 / 2;   // ワード数
                  IF EM45:Z9 > 0 THEN
                    EM45:Z9 := EM45:Z9 - 1;
                    FOR EM42:Z9 := 0 TO EM45:Z9 DO
                      Z3 := EM1.L:Z1;
                      Z3 := Z3 * 52 + 1000 + Z9;
                      Z3 := EM42:Z9 + Z3 + 4;
                      EM44:Z9 := EM0:Z3;
                      Z3 := EM1.L:Z2;
                      Z3 := Z3 * 52 + 1000 + Z9;
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
            EM1.L:Z1 := 0;
            EM0:Z1 := 2;
          ELSE
            EM1.L:Z1 := 1;
            EM0:Z1 := 3;
          END_IF;
        ELSIF Z5 = 2 THEN
          // !
          IF EM0:Z1 > 2 THEN
            EM1.L:Z1 := 0;
            EM0:Z1 := 2;
          ELSE
            EM1.L:Z1 := 1;
            EM0:Z1 := 3;
          END_IF;
        ELSIF Z5 = 3 THEN
          // %
          // 整数どうしのみ。実数の % は未対応
          IF EM0:Z2 = 4 THEN
            IF EM0:Z1 = 4 THEN
              IF EM1.L:Z2 <> 0 THEN
                EM16.L:Z9 := EM1.L:Z1;   // 被除数を退避
                EM1.L:Z1 := EM1.L:Z1 / EM1.L:Z2;   // 0方向へ切り捨てた商
                EM18.L:Z9 := EM16.L:Z9 - EM1.L:Z1 * EM1.L:Z2;   // 余り
                IF EM18.L:Z9 <> 0 THEN
                  // 符号が違うときだけ除数を足して符号を合わせる
                  IF EM16.L:Z9 < 0 THEN
                    IF EM1.L:Z2 > 0 THEN
                      EM18.L:Z9 := EM18.L:Z9 + EM1.L:Z2;
                    END_IF;
                  ELSE
                    IF EM1.L:Z2 < 0 THEN
                      EM18.L:Z9 := EM18.L:Z9 + EM1.L:Z2;
                    END_IF;
                  END_IF;
                END_IF;
                EM1.L:Z1 := EM18.L:Z9;
                EM0:Z1 := 4;
              ELSE
                EM1:Z9 := 3;
                EM2:Z9 := 1;
                EXIT;
              END_IF;
            ELSE
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
          ELSE
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
        ELSIF Z5 = 4 THEN
          // abs
          IF EM0:Z1 = 5 THEN
            IF EM1.F:Z1 < 0 THEN
              EM1.F:Z1 := 0 - EM1.F:Z1;
            END_IF;
          ELSE
            IF EM1.L:Z1 < 0 THEN
              EM1.L:Z1 := 0 - EM1.L:Z1;
            END_IF;
          END_IF;
        ELSIF Z5 = 5 THEN
          // to_i
          IF EM0:Z1 = 5 THEN
            // 0 方向へ切り捨て (Ruby の Float#to_i と同じ)
            EM16.L:Z9 := EM1.F:Z1;
            // この機種の実数→整数は四捨五入。0 方向へ 1 だけ戻す
            IF EM1.F:Z1 >= 0 THEN
              IF EM16.L:Z9 > EM1.F:Z1 THEN
                EM16.L:Z9 := EM16.L:Z9 - 1;
              END_IF;
            ELSE
              IF EM16.L:Z9 < EM1.F:Z1 THEN
                EM16.L:Z9 := EM16.L:Z9 + 1;
              END_IF;
            END_IF;
            EM1.L:Z1 := EM16.L:Z9;
            EM0:Z1 := 4;
          END_IF;
        ELSIF Z5 = 6 THEN
          // to_f
          IF EM0:Z1 = 4 THEN
            // 整数→実数。同じスロットを .L で読んで .F で書くためスクラッチを挟む
            EM18.F:Z9 := EM1.L:Z1;
            EM1.F:Z1 := EM18.F:Z9;
            EM0:Z1 := 5;
          END_IF;
        ELSIF Z5 = 7 THEN
          // floor
          IF EM0:Z1 = 5 THEN
            // KV の実数→整数は 0 方向へ切り捨て。負で端数があるときだけ 1 引く
            EM16.L:Z9 := EM1.F:Z1;
            // この機種の実数→整数は四捨五入。0 方向へ 1 だけ戻す
            IF EM1.F:Z1 >= 0 THEN
              IF EM16.L:Z9 > EM1.F:Z1 THEN
                EM16.L:Z9 := EM16.L:Z9 - 1;
              END_IF;
            ELSE
              IF EM16.L:Z9 < EM1.F:Z1 THEN
                EM16.L:Z9 := EM16.L:Z9 + 1;
              END_IF;
            END_IF;
            IF EM1.F:Z1 < 0 THEN
              IF EM16.L:Z9 <> EM1.F:Z1 THEN
                EM16.L:Z9 := EM16.L:Z9 - 1;
              END_IF;
            END_IF;
            EM1.L:Z1 := EM16.L:Z9;
            EM0:Z1 := 4;
          END_IF;
        ELSIF Z5 = 8 THEN
          // round
          IF EM0:Z1 = 5 THEN
            // Ruby の round は 0 から遠い方へ丸める (2.5→3, -2.5→-3)
            IF EM1.F:Z1 >= 0 THEN
              EM18.F:Z9 := EM1.F:Z1 + 0.5;
            ELSE
              EM18.F:Z9 := EM1.F:Z1 - 0.5;
            END_IF;
            EM16.L:Z9 := EM18.F:Z9;
            // この機種の実数→整数は四捨五入。0 方向へ 1 だけ戻す
            IF EM18.F:Z9 >= 0 THEN
              IF EM16.L:Z9 > EM18.F:Z9 THEN
                EM16.L:Z9 := EM16.L:Z9 - 1;
              END_IF;
            ELSE
              IF EM16.L:Z9 < EM18.F:Z9 THEN
                EM16.L:Z9 := EM16.L:Z9 + 1;
              END_IF;
            END_IF;
            EM1.L:Z1 := EM16.L:Z9;
            EM0:Z1 := 4;
          END_IF;
        ELSIF Z5 = 9 THEN
          // -@
          IF EM0:Z1 = 5 THEN
            EM1.F:Z1 := 0 - EM1.F:Z1;
          ELSE
            EM1.L:Z1 := 0 - EM1.L:Z1;
          END_IF;
        ELSIF Z5 = 10 THEN
          // +@
          // +x は何もしない (Ruby と同じ)
        ELSIF Z5 = 13 THEN
          // &
          IF EM0:Z1 <> 4 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          IF EM0:Z2 <> 4 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          EM1.L:Z1 := EM1.L:Z1 AND EM1.L:Z2;
          EM0:Z1 := 4;
        ELSIF Z5 = 14 THEN
          // |
          IF EM0:Z1 <> 4 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          IF EM0:Z2 <> 4 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          EM1.L:Z1 := EM1.L:Z1 OR EM1.L:Z2;
          EM0:Z1 := 4;
        ELSIF Z5 = 15 THEN
          // ^
          IF EM0:Z1 <> 4 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          IF EM0:Z2 <> 4 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          EM1.L:Z1 := EM1.L:Z1 XOR EM1.L:Z2;
          EM0:Z1 := 4;
        ELSIF Z5 = 16 THEN
          // ~
          IF EM0:Z1 <> 4 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          EM1.L:Z1 := -(EM1.L:Z1);
          EM1.L:Z1 := EM1.L:Z1 - 1;   // ~x = -x - 1
        ELSIF Z5 = 17 THEN
          // >>
          IF EM0:Z1 <> 4 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          IF EM0:Z2 <> 4 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          EM18.L:Z9 := EM1.L:Z2;   // 桁数
          IF EM18.L:Z9 < 0 THEN
            // 桁数が負なら向きが逆 (Ruby と同じ)
            EM18.L:Z9 := 0 - EM18.L:Z9;
            IF EM18.L:Z9 >= 32 THEN
              // 全部ずれる。左は 0、右は符号で埋まる
              EM1.L:Z1 := 0;
            ELSE
              EM1.L:Z1 := SHL(EM1.L:Z1, EM18.L:Z9);
            END_IF;
          ELSE
            IF EM18.L:Z9 >= 32 THEN
              // 全部ずれる。左は 0、右は符号で埋まる
              IF EM1.L:Z1 < 0 THEN
                EM1.L:Z1 := -1;
              ELSE
                EM1.L:Z1 := 0;
              END_IF;
            ELSE
              IF EM1.L:Z1 < 0 THEN
                // 負は反転して正にしてからずらし、戻す。符号が保たれる
                EM16.L:Z9 := -(EM1.L:Z1);
                EM16.L:Z9 := EM16.L:Z9 - 1;   // ~x = -x - 1
                EM16.L:Z9 := SHR(EM16.L:Z9, EM18.L:Z9);
                EM1.L:Z1 := -(EM16.L:Z9);
                EM1.L:Z1 := EM1.L:Z1 - 1;   // ~x = -x - 1
              ELSE
                EM1.L:Z1 := SHR(EM1.L:Z1, EM18.L:Z9);
              END_IF;
            END_IF;
          END_IF;
          EM0:Z1 := 4;
        ELSIF Z5 = 18 THEN
          // length
          IF EM0:Z1 = 9 THEN
            // 鍵の配列の見出し。R[a] を書き換える前に読む
            Z4 := EM1:Z1;
            Z4 := Z4 * 52 + 1000 + Z9;
            EM18.L:Z9 := EM0:Z4;   // 組の数
          ELSE
            // スロットの見出し。R[a] を書き換える前に読む
            Z4 := EM1.L:Z1;
            Z4 := Z4 * 52 + 1000 + Z9;
            EM18.L:Z9 := EM0:Z4;   // 要素数
            IF EM0:Z1 = 7 THEN
              // 文字列は文字数を返す。バイト数ではない
              EM49:Z9 := 65535;   // 数えるだけ
              // 文字の切れ目を先頭から数える。バイト列は 1 回だけなめる
              EM45:Z9 := EM0:Z4;   // バイト数
              EM47:Z9 := 0;
              EM48:Z9 := 0;
              EM50:Z9 := EM45:Z9;   // 見つからなければバイト数のまま
              EM51:Z9 := EM45:Z9;
              IF EM45:Z9 > 0 THEN
                Z6 := EM45:Z9;
                Z6 := Z6 - 1;
                FOR EM42:Z9 := 0 TO Z6 DO
                  Z8 := EM42:Z9 / 2;
                  Z7 := Z8 + Z4 + 4;
                  Z7 := EM0:Z7;
                  Z8 := Z7 / 256;
                  Z7 := Z7 - Z8 * 256;
                  IF EM42:Z9 - (EM42:Z9 / 2) * 2 = 0 THEN
                    Z7 := Z8;   // 偶数の位置は上位バイト
                  END_IF;
                  // この位置が文字の先頭かどうか
                  EM43:Z9 := 1;
                  IF EM40:Z9 = 0 THEN
                    // 継続バイト (10xxxxxx) は文字の途中
                    IF Z7 >= 128 THEN
                      IF Z7 < 192 THEN
                        EM43:Z9 := 0;
                      END_IF;
                    END_IF;
                  ELSIF EM40:Z9 = 1 THEN
                    IF EM48:Z9 = 1 THEN
                      // 先導バイトの次は後続バイト
                      EM43:Z9 := 0;
                      EM48:Z9 := 0;
                    ELSE
                      // 先導バイト (0x81-0x9F, 0xE0-0xEF) なら次のバイトは後続
                      IF Z7 >= 129 THEN
                        IF Z7 <= 159 THEN
                          EM48:Z9 := 1;
                        END_IF;
                      END_IF;
                      IF Z7 >= 224 THEN
                        IF Z7 <= 239 THEN
                          EM48:Z9 := 1;
                        END_IF;
                      END_IF;
                    END_IF;
                  END_IF;
                  // ASCII はどのバイトも文字の先頭なので何も見ない
                  IF EM43:Z9 = 1 THEN
                    IF EM49:Z9 <= 96 THEN
                      // 探している文字なら位置を控える。次の切れ目がその文字の終わり
                      IF EM47:Z9 = EM49:Z9 THEN
                        EM50:Z9 := EM42:Z9;
                      END_IF;
                      Z7 := EM49:Z9 + 1;
                      IF EM47:Z9 = Z7 THEN
                        EM51:Z9 := EM42:Z9;
                      END_IF;
                    END_IF;
                    EM47:Z9 := EM47:Z9 + 1;
                  END_IF;
                END_FOR;
              END_IF;
              EM18.L:Z9 := EM47:Z9;
            END_IF;
          END_IF;
          EM1.L:Z1 := EM18.L:Z9;
          EM0:Z1 := 4;
        ELSIF Z5 = 19 THEN
          // empty?
          IF EM0:Z1 = 9 THEN
            // 鍵の配列の見出し。R[a] を書き換える前に読む
            Z4 := EM1:Z1;
            Z4 := Z4 * 52 + 1000 + Z9;
            EM18.L:Z9 := EM0:Z4;   // 組の数
          ELSE
            // スロットの見出し。R[a] を書き換える前に読む
            Z4 := EM1.L:Z1;
            Z4 := Z4 * 52 + 1000 + Z9;
            EM18.L:Z9 := EM0:Z4;   // 要素数
          END_IF;
          IF EM18.L:Z9 = 0 THEN
            EM1.L:Z1 := 1;
            EM0:Z1 := 3;
          ELSE
            EM1.L:Z1 := 0;
            EM0:Z1 := 2;
          END_IF;
        ELSIF Z5 = 20 THEN
          // <<
          IF EM0:Z1 = 4 THEN
            IF EM0:Z1 <> 4 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
            IF EM0:Z2 <> 4 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 4;
              EXIT;
            END_IF;
            EM18.L:Z9 := EM1.L:Z2;   // 桁数
            IF EM18.L:Z9 < 0 THEN
              // 桁数が負なら向きが逆 (Ruby と同じ)
              EM18.L:Z9 := 0 - EM18.L:Z9;
              IF EM18.L:Z9 >= 32 THEN
                // 全部ずれる。左は 0、右は符号で埋まる
                IF EM1.L:Z1 < 0 THEN
                  EM1.L:Z1 := -1;
                ELSE
                  EM1.L:Z1 := 0;
                END_IF;
              ELSE
                IF EM1.L:Z1 < 0 THEN
                  // 負は反転して正にしてからずらし、戻す。符号が保たれる
                  EM16.L:Z9 := -(EM1.L:Z1);
                  EM16.L:Z9 := EM16.L:Z9 - 1;   // ~x = -x - 1
                  EM16.L:Z9 := SHR(EM16.L:Z9, EM18.L:Z9);
                  EM1.L:Z1 := -(EM16.L:Z9);
                  EM1.L:Z1 := EM1.L:Z1 - 1;   // ~x = -x - 1
                ELSE
                  EM1.L:Z1 := SHR(EM1.L:Z1, EM18.L:Z9);
                END_IF;
              END_IF;
            ELSE
              IF EM18.L:Z9 >= 32 THEN
                // 全部ずれる。左は 0、右は符号で埋まる
                EM1.L:Z1 := 0;
              ELSE
                EM1.L:Z1 := SHL(EM1.L:Z1, EM18.L:Z9);
              END_IF;
            END_IF;
            EM0:Z1 := 4;
          ELSIF EM0:Z1 = 7 THEN
            // 文字列は中身を継ぎ足す
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
          ELSIF EM0:Z1 = 8 THEN
            // スロットの見出し。R[a] を書き換える前に読む
            Z4 := EM1.L:Z1;
            Z4 := Z4 * 52 + 1000 + Z9;
            EM18.L:Z9 := EM0:Z4;   // 要素数
            IF EM18.L:Z9 >= 12 THEN
              // 1 スロットの容量がいっぱい
              EM1:Z9 := 3;
              EM2:Z9 := 10;
              EXIT;
            END_IF;
            // 末尾に足して要素数を 1 増やす
            EM16.L:Z9 := EM18.L:Z9;
            Z5 := EM16.L:Z9;
            Z5 := Z5 * 4 + Z4 + 4;
            EM1.L:Z5 := EM1.L:Z2;
            EM0:Z5 := EM0:Z2;
            Z6 := EM18.L:Z9;
            EM0:Z4 := Z6 + 1;
          ELSE
            // 実数とシンボルは区分の範囲に入ってしまうのでここで弾く
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
        ELSIF Z5 = 22 THEN
          // push
          // スロットの見出し。R[a] を書き換える前に読む
          Z4 := EM1.L:Z1;
          Z4 := Z4 * 52 + 1000 + Z9;
          EM18.L:Z9 := EM0:Z4;   // 要素数
          IF EM18.L:Z9 >= 12 THEN
            // 1 スロットの容量がいっぱい
            EM1:Z9 := 3;
            EM2:Z9 := 10;
            EXIT;
          END_IF;
          // 末尾に足して要素数を 1 増やす
          EM16.L:Z9 := EM18.L:Z9;
          Z5 := EM16.L:Z9;
          Z5 := Z5 * 4 + Z4 + 4;
          EM1.L:Z5 := EM1.L:Z2;
          EM0:Z5 := EM0:Z2;
          Z6 := EM18.L:Z9;
          EM0:Z4 := Z6 + 1;
        ELSIF Z5 = 23 THEN
          // key?
          // 鍵の配列の見出し。R[a] を書き換える前に読む
          Z4 := EM1:Z1;
          Z4 := Z4 * 52 + 1000 + Z9;
          EM18.L:Z9 := EM0:Z4;   // 組の数
          // 鍵を先頭から探す。一致は型と値の両方 (Ruby の eql? と同じ)
          EM16.L:Z9 := -1;
          IF EM18.L:Z9 > 0 THEN
            Z8 := EM18.L:Z9;
            Z8 := Z8 - 1;
            FOR Z6 := 0 TO Z8 DO
              IF EM16.L:Z9 < 0 THEN
                // 最初に一致したものを採る
                Z7 := Z6 * 4 + Z4 + 4;
                IF EM0:Z7 = EM0:Z2 THEN
                  IF EM0:Z2 = 7 THEN
                    // 文字列の鍵は中身で照合する。スロットが違っても同じ鍵
                    // 文字列は中身で比べる。スロット番号ではない
                    // Z3 を借りる。返すまでの間に呼ぶ側の値を壊さないため
                    EM46:Z9 := Z3;
                    EM43:Z9 := 0;
                    Z3 := EM1.L:Z7;
                    Z3 := Z3 * 52 + 1000 + Z9;
                    EM44:Z9 := EM0:Z3;   // バイト数
                    Z3 := EM1.L:Z2;
                    Z3 := Z3 * 52 + 1000 + Z9;
                    IF EM44:Z9 = EM0:Z3 THEN
                      // バイト数が同じ。ここから中身を見る
                      EM43:Z9 := 1;
                      EM45:Z9 := EM44:Z9 + 1;
                      EM45:Z9 := EM45:Z9 / 2;   // ワード数
                      IF EM45:Z9 > 0 THEN
                        EM45:Z9 := EM45:Z9 - 1;
                        FOR EM42:Z9 := 0 TO EM45:Z9 DO
                          Z3 := EM1.L:Z7;
                          Z3 := Z3 * 52 + 1000 + Z9;
                          Z3 := EM42:Z9 + Z3 + 4;
                          EM44:Z9 := EM0:Z3;
                          Z3 := EM1.L:Z2;
                          Z3 := Z3 * 52 + 1000 + Z9;
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
                      EM16.L:Z9 := Z6;
                    END_IF;
                  ELSE
                    IF EM1.L:Z7 = EM1.L:Z2 THEN
                      EM16.L:Z9 := Z6;
                    END_IF;
                  END_IF;
                END_IF;
              END_IF;
            END_FOR;
          END_IF;
          IF EM16.L:Z9 < 0 THEN
            EM1.L:Z1 := 0;
            EM0:Z1 := 2;
          ELSE
            EM1.L:Z1 := 1;
            EM0:Z1 := 3;
          END_IF;
        ELSIF Z5 = 24 THEN
          // keys
          // プールの空きスロットを取る。返さないので使い切ったら止まる
          IF EM39:Z9 >= 16 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 10;
            EXIT;
          END_IF;
          // 鍵の配列の見出し。R[a] を書き換える前に読む
          Z4 := EM1:Z1;
          Z4 := Z4 * 52 + 1000 + Z9;
          EM18.L:Z9 := EM0:Z4;   // 組の数
          Z5 := EM2:Z1;   // 値の配列
          Z5 := Z5 * 52 + 1000 + Z9;
          // 新しいスロットの見出し。組の数がそのまま要素数になる
          Z2 := EM39:Z9 * 52 + 1000 + Z9;
          EM0:Z2 := EM18.L:Z9;
          // 写す。組の数 0 (空ハッシュ) では引き算もしない
          IF EM18.L:Z9 > 0 THEN
            Z8 := EM18.L:Z9;
            Z8 := Z8 - 1;
            FOR Z6 := 0 TO Z8 DO
              Z7 := Z6 * 4 + Z4 + 4;
              Z3 := Z6 * 4 + Z2 + 4;
              EM1.L:Z3 := EM1.L:Z7;
              EM0:Z3 := EM0:Z7;
            END_FOR;
          END_IF;
          // R[a] はハッシュから配列に変わる。値ワードを 32 ビットで書くので
          // 上位に入っていた値の配列のスロット番号も消える
          EM1.L:Z1 := EM39:Z9;   // スロット番号
          EM0:Z1 := 8;
          EM39:Z9 := EM39:Z9 + 1;
        ELSIF Z5 = 25 THEN
          // values
          // プールの空きスロットを取る。返さないので使い切ったら止まる
          IF EM39:Z9 >= 16 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 10;
            EXIT;
          END_IF;
          // 鍵の配列の見出し。R[a] を書き換える前に読む
          Z4 := EM1:Z1;
          Z4 := Z4 * 52 + 1000 + Z9;
          EM18.L:Z9 := EM0:Z4;   // 組の数
          Z5 := EM2:Z1;   // 値の配列
          Z5 := Z5 * 52 + 1000 + Z9;
          // 新しいスロットの見出し。組の数がそのまま要素数になる
          Z2 := EM39:Z9 * 52 + 1000 + Z9;
          EM0:Z2 := EM18.L:Z9;
          // 写す。組の数 0 (空ハッシュ) では引き算もしない
          IF EM18.L:Z9 > 0 THEN
            Z8 := EM18.L:Z9;
            Z8 := Z8 - 1;
            FOR Z6 := 0 TO Z8 DO
              Z7 := Z6 * 4 + Z5 + 4;
              Z3 := Z6 * 4 + Z2 + 4;
              EM1.L:Z3 := EM1.L:Z7;
              EM0:Z3 := EM0:Z7;
            END_FOR;
          END_IF;
          // R[a] はハッシュから配列に変わる。値ワードを 32 ビットで書くので
          // 上位に入っていた値の配列のスロット番号も消える
          EM1.L:Z1 := EM39:Z9;   // スロット番号
          EM0:Z1 := 8;
          EM39:Z9 := EM39:Z9 + 1;
        ELSIF Z5 = 26 THEN
          // []
          Z3 := (EM7:Z9 + 2) * 4 + EM32:Z9 + Z9;
          IF EM0:Z3 <> 4 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          IF EM0:Z2 <> 4 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          // デバイス参照から種別と幅を取り出す
          Z8 := EM2:Z1 / 16;   // アクセス幅
          Z5 := EM2:Z1 - Z8 * 16;   // デバイス種別
          // 個別ビットは読めない。1 要素が何ビットか決まらない
          IF Z8 = 5 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          // 生成コードが知っている種別か。知らない種別は FOR に入る前に弾く
          EM47:Z9 := 0;
          IF Z5 = 0 THEN
            EM47:Z9 := 1;
          END_IF;
          IF Z5 = 1 THEN
            EM47:Z9 := 1;
          END_IF;
          IF Z5 = 2 THEN
            EM47:Z9 := 1;
          END_IF;
          IF Z5 = 3 THEN
            EM47:Z9 := 1;
          END_IF;
          IF Z5 = 4 THEN
            EM47:Z9 := 1;
          END_IF;
          IF Z5 = 5 THEN
            EM47:Z9 := 1;
          END_IF;
          IF Z5 = 6 THEN
            EM47:Z9 := 1;
          END_IF;
          IF EM47:Z9 = 0 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          // 刻み。幅のワード数、ビットデバイスならその 16 倍
          EM45:Z9 := 1;
          IF Z8 = 2 THEN
            EM45:Z9 := 2;
          END_IF;
          IF Z8 = 3 THEN
            EM45:Z9 := 2;
          END_IF;
          IF Z8 = 4 THEN
            EM45:Z9 := 2;
          END_IF;
          IF Z5 > 2 THEN
            EM45:Z9 := EM45:Z9 * 16;
          END_IF;
          EM18.L:Z9 := EM1.L:Z3;   // 個数
          EM44:Z9 := EM1:Z1 + EM1.L:Z2;   // 読み始め
          IF EM18.L:Z9 < 0 THEN
            // 個数が負なら nil (Ruby と同じ)
            EM1.L:Z1 := 0;
            EM0:Z1 := 1;
          ELSE
            IF EM18.L:Z9 > 12 THEN
              // 1 スロットの容量を超える個数
              EM1:Z9 := 3;
              EM2:Z9 := 10;
              EXIT;
            END_IF;
            // プールの空きスロットを取る。返さないので使い切ったら止まる
            IF EM39:Z9 >= 16 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 10;
              EXIT;
            END_IF;
            Z4 := EM39:Z9 * 52 + 1000 + Z9;
            EM0:Z4 := EM18.L:Z9;
            IF EM18.L:Z9 > 0 THEN
              Z7 := EM18.L:Z9;
              Z7 := Z7 - 1;
              FOR EM42:Z9 := 0 TO Z7 DO
                Z6 := EM42:Z9 * EM45:Z9 + EM44:Z9;   // 読み先
                Z3 := EM42:Z9 * 4 + Z4 + 4;
                // デバイスタイプ別読み取り
                // ワードデバイス (EM, DM, ZF): Z8 (access_type) で幅を選ぶ
                //   2=.L(32bit符号付き)
                //   1=.U(16bit符号なし)
                //   3=.D(32bit符号なし)
                //   4=.F(実数)
                //   それ以外=.S(16bit符号付き/既定)
                // ビットデバイス (R, MR, B, LR): ON→true, OFF→false
                //   整数の 1/0 ではなく真偽値。0 は Ruby では真なので、
                //   整数にすると if $MR10 が常に成立してしまう
                IF Z5 = 0 THEN
                  IF Z8 = 2 THEN
                    EM1.L:Z3 := EM0.L:Z6;
                    EM0:Z3 := 4;
                  ELSIF Z8 = 1 THEN
                    EM1.L:Z3 := EM0.U:Z6;
                    EM0:Z3 := 4;
                  ELSIF Z8 = 3 THEN
                    EM1.L:Z3 := EM0.D:Z6;
                    EM0:Z3 := 4;
                  ELSIF Z8 = 4 THEN
                    EM1.F:Z3 := EM0.F:Z6;
                    EM0:Z3 := 5;
                  ELSE
                    EM1.L:Z3 := EM0.S:Z6;
                    EM0:Z3 := 4;
                  END_IF;
                ELSIF Z5 = 1 THEN
                  IF Z8 = 2 THEN
                    EM1.L:Z3 := DM0.L:Z6;
                    EM0:Z3 := 4;
                  ELSIF Z8 = 1 THEN
                    EM1.L:Z3 := DM0.U:Z6;
                    EM0:Z3 := 4;
                  ELSIF Z8 = 3 THEN
                    EM1.L:Z3 := DM0.D:Z6;
                    EM0:Z3 := 4;
                  ELSIF Z8 = 4 THEN
                    EM1.F:Z3 := DM0.F:Z6;
                    EM0:Z3 := 5;
                  ELSE
                    EM1.L:Z3 := DM0.S:Z6;
                    EM0:Z3 := 4;
                  END_IF;
                ELSIF Z5 = 2 THEN
                  IF Z8 = 2 THEN
                    EM1.L:Z3 := ZF0.L:Z6;
                    EM0:Z3 := 4;
                  ELSIF Z8 = 1 THEN
                    EM1.L:Z3 := ZF0.U:Z6;
                    EM0:Z3 := 4;
                  ELSIF Z8 = 3 THEN
                    EM1.L:Z3 := ZF0.D:Z6;
                    EM0:Z3 := 4;
                  ELSIF Z8 = 4 THEN
                    EM1.F:Z3 := ZF0.F:Z6;
                    EM0:Z3 := 5;
                  ELSE
                    EM1.L:Z3 := ZF0.S:Z6;
                    EM0:Z3 := 4;
                  END_IF;
                ELSIF Z5 = 3 THEN
                  IF Z8 = 5 THEN
                    IF R0:Z6 THEN
                      EM1.L:Z3 := 1;
                      EM0:Z3 := 3;
                    ELSE
                      EM1.L:Z3 := 0;
                      EM0:Z3 := 2;
                    END_IF;
                  ELSE
                    IF Z8 = 2 THEN
                      EM1.L:Z3 := R0.L:Z6;
                      EM0:Z3 := 4;
                    ELSIF Z8 = 1 THEN
                      EM1.L:Z3 := R0.U:Z6;
                      EM0:Z3 := 4;
                    ELSIF Z8 = 3 THEN
                      EM1.L:Z3 := R0.D:Z6;
                      EM0:Z3 := 4;
                    ELSIF Z8 = 4 THEN
                      EM1.F:Z3 := R0.F:Z6;
                      EM0:Z3 := 5;
                    ELSE
                      EM1.L:Z3 := R0.S:Z6;
                      EM0:Z3 := 4;
                    END_IF;
                  END_IF;
                ELSIF Z5 = 4 THEN
                  IF Z8 = 5 THEN
                    IF MR0:Z6 THEN
                      EM1.L:Z3 := 1;
                      EM0:Z3 := 3;
                    ELSE
                      EM1.L:Z3 := 0;
                      EM0:Z3 := 2;
                    END_IF;
                  ELSE
                    IF Z8 = 2 THEN
                      EM1.L:Z3 := MR0.L:Z6;
                      EM0:Z3 := 4;
                    ELSIF Z8 = 1 THEN
                      EM1.L:Z3 := MR0.U:Z6;
                      EM0:Z3 := 4;
                    ELSIF Z8 = 3 THEN
                      EM1.L:Z3 := MR0.D:Z6;
                      EM0:Z3 := 4;
                    ELSIF Z8 = 4 THEN
                      EM1.F:Z3 := MR0.F:Z6;
                      EM0:Z3 := 5;
                    ELSE
                      EM1.L:Z3 := MR0.S:Z6;
                      EM0:Z3 := 4;
                    END_IF;
                  END_IF;
                ELSIF Z5 = 5 THEN
                  IF Z8 = 5 THEN
                    IF B0:Z6 THEN
                      EM1.L:Z3 := 1;
                      EM0:Z3 := 3;
                    ELSE
                      EM1.L:Z3 := 0;
                      EM0:Z3 := 2;
                    END_IF;
                  ELSE
                    IF Z8 = 2 THEN
                      EM1.L:Z3 := B0.L:Z6;
                      EM0:Z3 := 4;
                    ELSIF Z8 = 1 THEN
                      EM1.L:Z3 := B0.U:Z6;
                      EM0:Z3 := 4;
                    ELSIF Z8 = 3 THEN
                      EM1.L:Z3 := B0.D:Z6;
                      EM0:Z3 := 4;
                    ELSIF Z8 = 4 THEN
                      EM1.F:Z3 := B0.F:Z6;
                      EM0:Z3 := 5;
                    ELSE
                      EM1.L:Z3 := B0.S:Z6;
                      EM0:Z3 := 4;
                    END_IF;
                  END_IF;
                ELSIF Z5 = 6 THEN
                  IF Z8 = 5 THEN
                    IF LR0:Z6 THEN
                      EM1.L:Z3 := 1;
                      EM0:Z3 := 3;
                    ELSE
                      EM1.L:Z3 := 0;
                      EM0:Z3 := 2;
                    END_IF;
                  ELSE
                    IF Z8 = 2 THEN
                      EM1.L:Z3 := LR0.L:Z6;
                      EM0:Z3 := 4;
                    ELSIF Z8 = 1 THEN
                      EM1.L:Z3 := LR0.U:Z6;
                      EM0:Z3 := 4;
                    ELSIF Z8 = 3 THEN
                      EM1.L:Z3 := LR0.D:Z6;
                      EM0:Z3 := 4;
                    ELSIF Z8 = 4 THEN
                      EM1.F:Z3 := LR0.F:Z6;
                      EM0:Z3 := 5;
                    ELSE
                      EM1.L:Z3 := LR0.S:Z6;
                      EM0:Z3 := 4;
                    END_IF;
                  END_IF;
                ELSE
                  // 呼ぶ側が種別を確かめている。ここへは来ない
                END_IF;
              END_FOR;
            END_IF;
            // R[a] はデバイス参照から配列に変わる
            EM1.L:Z1 := EM39:Z9;   // スロット番号
            EM0:Z1 := 8;
            EM39:Z9 := EM39:Z9 + 1;
          END_IF;
        ELSE
          // 未対応のメソッド (ブロックを取るメソッドをブロック無しで呼んだ場合も含む)
          EM1:Z9 := 3;
          EM2:Z9 := 3;
          EXIT;
        END_IF;
      ELSE
        IF Z6 = 0 THEN
          // 組み込みでもユーザー定義でもない
          EM1:Z9 := 3;
          EM2:Z9 := 3;
          EXIT;
        END_IF;
        Z3 := Z6 + 536 + Z9;
        Z5 := EM0:Z3;   // 本体の irep 番号
        IF Z5 = 0 THEN
          // まだ def が実行されていない
          EM1:Z9 := 3;
          EM2:Z9 := 3;
          EXIT;
        END_IF;
        IF EM31:Z9 >= 16 THEN
          // 呼び出しが深すぎる。PLC はメモリ固定なので上限で止めるしかない
          EM1:Z9 := 3;
          EM2:Z9 := 5;
          EXIT;
        END_IF;
        // 戻り先を積む
        Z3 := EM31:Z9 * 10 + 376 + Z9;
        EM0:Z3 := EM0:Z9;
        EM1:Z3 := EM30:Z9;
        EM2:Z3 := EM32:Z9;
        EM4:Z3 := 65535;
        EM5:Z3 := 0;
        // レジスタ窓をずらす。呼ばれた側の R[0] が呼んだ側の R[a]
        EM32:Z9 := EM32:Z9 + EM7:Z9 * 4;
        EM3:Z3 := EM32:Z9;   // このフレームの窓 (OP_GETUPVAR が見る)
        EM31:Z9 := EM31:Z9 + 1;
        EM37:Z9 := EM9:Z9;
        EM30:Z9 := Z5;
        // IREP テーブルから実行中の irep の情報を写す
        Z1 := Z5 * 8 + EM38:Z9;
        EM33:Z9 := FM0:Z1;
        EM10:Z9 := FM1:Z1;
        EM34:Z9 := FM2:Z1;
        EM35:Z9 := FM3:Z1;
        EM11:Z9 := FM4:Z1;
        // レジスタ窓が領域からはみ出さないこと
        EM16:Z9 := EM32:Z9 + EM11:Z9 * 4;
        IF EM16:Z9 > 376 THEN
          EM1:Z9 := 3;
          EM2:Z9 := 5;
          EXIT;
        END_IF;
        EM0:Z9 := 0;
      END_IF;

    ELSIF EM6:Z9 = 48 THEN
      // OP_SENDB (BBB): R[a].symbols[b](R[a+1]..) { ブロック }
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM9:Z9 := FM0:Z1;
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
      // ブロックを取るメソッドはレシーバの型で並んでいるため連続していない
      Z6 := 0;
      IF Z5 = 11 THEN
        Z6 := 1;
      END_IF;
      IF Z5 = 12 THEN
        Z6 := 1;
      END_IF;
      IF Z5 = 21 THEN
        Z6 := 1;
      END_IF;
      IF Z6 = 0 THEN
        // ブロックを取らないメソッドにブロックを渡した
        EM1:Z9 := 3;
        EM2:Z9 := 3;
        EXIT;
      END_IF;
      IF EM9:Z9 <> Z8 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 3;
        EXIT;
      END_IF;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      // メソッド番号の区分ごとにレシーバのタグの範囲を見る (METHOD_RECEIVER_GROUPS)
      // 3 未満 (!= と !) はどの型でも呼べる
      IF Z5 >= 3 THEN
        IF Z5 <= 17 THEN
          // 数値 (タグ 4-5)
          IF EM0:Z1 < 4 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          IF EM0:Z1 > 5 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
        ELSIF Z5 <= 19 THEN
          // 文字列・配列・ハッシュ (タグ 7-9)
          IF EM0:Z1 < 7 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          IF EM0:Z1 > 9 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
        ELSIF Z5 <= 20 THEN
          // 整数・文字列・配列 (タグ 4-8)
          IF EM0:Z1 < 4 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          IF EM0:Z1 > 8 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
        ELSIF Z5 <= 21 THEN
          // 配列・ハッシュ (タグ 8-9)
          IF EM0:Z1 < 8 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
          IF EM0:Z1 > 9 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
        ELSIF Z5 <= 22 THEN
          // 配列 (タグ 8)
          IF EM0:Z1 <> 8 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
        ELSIF Z5 <= 25 THEN
          // ハッシュ (タグ 9)
          IF EM0:Z1 <> 9 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
        ELSE
          // デバイス参照 (タグ 11)
          IF EM0:Z1 <> 11 THEN
            EM1:Z9 := 3;
            EM2:Z9 := 4;
            EXIT;
          END_IF;
        END_IF;
      END_IF;
      // ブロックは引数の後ろ R[a + 引数の数 + 1] にある
      Z3 := (EM7:Z9 + EM9:Z9 + 1) * 4 + EM32:Z9 + Z9;
      IF EM0:Z3 <> 12 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 9;
        EXIT;
      END_IF;
      IF Z5 = 11 THEN
        // n.times は 0 から n-1 まで
        EM16.L:Z9 := 0;
        EM18.L:Z9 := EM1.L:Z1 - 1;
      ELSIF Z5 = 21 THEN
        // a.each / h.each は 0 から要素数-1 まで
        // ハッシュは組の数。どちらも Z5 (メソッド番号) を壊さない方で読む
        IF EM0:Z1 = 9 THEN
          // 鍵の配列の見出し。R[a] を書き換える前に読む
          Z4 := EM1:Z1;
          Z4 := Z4 * 52 + 1000 + Z9;
          EM18.L:Z9 := EM0:Z4;   // 組の数
        ELSE
          // スロットの見出し。R[a] を書き換える前に読む
          Z4 := EM1.L:Z1;
          Z4 := Z4 * 52 + 1000 + Z9;
          EM18.L:Z9 := EM0:Z4;   // 要素数
        END_IF;
        EM16.L:Z9 := 0;
        EM18.L:Z9 := EM18.L:Z9 - 1;
      ELSE
        // a.upto(b) は a から b まで
        Z2 := (EM7:Z9 + 1) * 4 + EM32:Z9 + Z9;
        IF EM0:Z2 <> 4 THEN
          EM1:Z9 := 3;
          EM2:Z9 := 4;
          EXIT;
        END_IF;
        EM16.L:Z9 := EM1.L:Z1;
        EM18.L:Z9 := EM1.L:Z2;
      END_IF;
      IF EM16.L:Z9 <= EM18.L:Z9 THEN
        IF EM31:Z9 >= 16 THEN
          // 呼び出しが深すぎる。PLC はメモリ固定なので上限で止めるしかない
          EM1:Z9 := 3;
          EM2:Z9 := 5;
          EXIT;
        END_IF;
        // 戻り先を積む
        Z3 := EM31:Z9 * 10 + 376 + Z9;
        EM0:Z3 := EM0:Z9;
        EM1:Z3 := EM30:Z9;
        EM2:Z3 := EM32:Z9;
        EM4:Z3 := 65535;
        EM5:Z3 := 1;
        // レジスタ窓をずらす。呼ばれた側の R[0] が呼んだ側の R[a]
        EM32:Z9 := EM32:Z9 + EM7:Z9 * 4;
        EM3:Z3 := EM32:Z9;   // このフレームの窓 (OP_GETUPVAR が見る)
        EM31:Z9 := EM31:Z9 + 1;
        IF Z5 = 21 THEN
          // each はブロックに添字ではなく要素を渡す
          // ハッシュは鍵と値の 2 つを渡すので種別を分ける
          Z4 := 0 + EM32:Z9 + Z9;   // 窓をずらした後の R[0] がレシーバ
          IF EM0:Z4 = 9 THEN
            EM5:Z3 := 3;
          ELSE
            EM5:Z3 := 2;
          END_IF;
        END_IF;
        // 窓をずらした後、ブロックは R[引数の数 + 1] にある
        Z2 := (EM9:Z9 + 1) * 4 + EM32:Z9 + Z9;
        Z6 := EM1:Z2;   // 本体の irep
        Z7 := EM2:Z2;   // 定義元のフレーム
        // 反復の状態と定義元をフレームに書く (Z3 は push_frame が指したまま)
        EM4:Z3 := Z7;
        EM6.L:Z3 := EM16.L:Z9;
        EM8.L:Z3 := EM18.L:Z9;
        // 渡す値と引数の数はどちらもフレームの種別で決まる。まとめて書く
        Z2 := 4 + EM32:Z9 + Z9;
        IF EM5:Z3 = 3 THEN
          // h.each は鍵と値を渡す。レシーバのハッシュは R[0] に残っている
          Z4 := 0 + EM32:Z9 + Z9;
          Z7 := EM1:Z4;   // スロット番号
          Z7 := Z7 * 52 + 1000 + Z9;
          Z5 := EM16.L:Z9;
          Z5 := Z5 * 4 + Z7 + 4;
          EM1.L:Z2 := EM1.L:Z5;
          EM0:Z2 := EM0:Z5;
          Z2 := 2 * 4 + EM32:Z9 + Z9;   // R[2] に値
          Z7 := EM2:Z4;   // スロット番号
          Z7 := Z7 * 52 + 1000 + Z9;
          Z5 := EM16.L:Z9;
          Z5 := Z5 * 4 + Z7 + 4;
          EM1.L:Z2 := EM1.L:Z5;
          EM0:Z2 := EM0:Z5;
          EM37:Z9 := 2;
        ELSIF EM5:Z3 = 2 THEN
          // a.each はその位置の要素を渡す。レシーバの配列は R[0] に残っている
          Z4 := 0 + EM32:Z9 + Z9;
          // **スロット番号は 2 つ目のスクラッチへ。** 1 つ目には反復の添字が
          // 載っていて、これから要素の位置を出すのに使う
          Z7 := EM1.L:Z4;   // スロット番号
          Z7 := Z7 * 52 + 1000 + Z9;
          Z5 := EM16.L:Z9;
          Z5 := Z5 * 4 + Z7 + 4;
          EM1.L:Z2 := EM1.L:Z5;
          EM0:Z2 := EM0:Z5;
          EM37:Z9 := 1;
        ELSE
          // times / upto は添字を渡す
          EM1.L:Z2 := EM16.L:Z9;
          EM0:Z2 := 4;
          EM37:Z9 := 1;
        END_IF;
        EM30:Z9 := Z6;
        // IREP テーブルから実行中の irep の情報を写す
        Z1 := Z6 * 8 + EM38:Z9;
        EM33:Z9 := FM0:Z1;
        EM10:Z9 := FM1:Z1;
        EM34:Z9 := FM2:Z1;
        EM35:Z9 := FM3:Z1;
        EM11:Z9 := FM4:Z1;
        // レジスタ窓が領域からはみ出さないこと
        EM16:Z9 := EM32:Z9 + EM11:Z9 * 4;
        IF EM16:Z9 > 376 THEN
          EM1:Z9 := 3;
          EM2:Z9 := 5;
          EXIT;
        END_IF;
        EM0:Z9 := 0;
      END_IF;
      // 1 回も回らないときはレシーバがそのまま呼び出しの値になる

    ELSIF EM6:Z9 = 52 THEN
      // OP_ENTER (W): 引数の数を検査し、残りのレジスタを空にする
      // 24bit big-endian。16ビットに収まらないため上位バイトと下位2バイトに分ける
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      Z3 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      Z4 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      EM8:Z9 := Z3 * 256 + Z4;   // aspec の下位2バイト
      // 必須引数の数 = aspec >> 18。上位バイトを 4 で割った値と同じ
      Z3 := EM7:Z9 / 4;
      IF EM7:Z9 <> Z3 * 4 THEN
        // 必須引数以外の指定 (省略可能・可変長・キーワード) は未対応
        EM1:Z9 := 3;
        EM2:Z9 := 6;
        EXIT;
      END_IF;
      IF EM8:Z9 <> 0 THEN
        EM1:Z9 := 3;
        EM2:Z9 := 6;
        EXIT;
      END_IF;
      // ブロックは引数の数を検査しない。Ruby は足りなければ nil、余れば捨てる
      // (引数を書かないブロックでも times は 1 個渡す)
      Z4 := 0;
      IF EM31:Z9 > 0 THEN
        Z5 := (EM31:Z9 - 1) * 10 + 376 + Z9;
        IF EM5:Z5 >= 1 THEN
          Z4 := 1;
        END_IF;
      END_IF;
      IF Z4 = 0 THEN
        IF EM37:Z9 <> Z3 THEN
          // 実引数の数が定義と違う
          EM1:Z9 := 3;
          EM2:Z9 := 6;
          EXIT;
        END_IF;
      END_IF;
      // 引数の後ろのレジスタを空にする (未代入のローカル変数は偽になる)
      // 受け取れなかった引数も空になる (Ruby の nil に相当)
      IF EM37:Z9 < Z3 THEN
        Z3 := EM37:Z9;
      END_IF;
      Z4 := (Z3 + 1) * 4 + EM32:Z9 + Z9;
      Z5 := EM11:Z9 * 4 + EM32:Z9 + Z9 - 1;
      IF Z4 <= Z5 THEN
        FOR Z6 := Z4 TO Z5 DO
          EM0:Z6 := 0;
        END_FOR;
      END_IF;

    ELSIF EM6:Z9 = 56 THEN
      // OP_RETURN (B): R[b] を返して呼び出し元へ (トップレベルでは VM 停止)
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      IF EM31:Z9 = 0 THEN
        // トップレベルの return は VM 停止
        EM1:Z9 := 2;
        EXIT;
      ELSE
        Z3 := (EM31:Z9 - 1) * 10 + 376 + Z9;
        IF EM5:Z3 >= 1 THEN
          EM16.L:Z9 := EM6.L:Z3 + 1;
          IF EM16.L:Z9 <= EM8.L:Z3 THEN
            // 次の回。PC を 0 に戻し、ブロックの引数を更新するだけ
            // irep もレジスタ窓もそのまま使い回す
            EM6.L:Z3 := EM16.L:Z9;
            Z2 := 4 + EM32:Z9 + Z9;
            IF EM5:Z3 = 3 THEN
              // h.each は鍵と値を渡す。レシーバのハッシュは R[0] に残っている
              Z4 := 0 + EM32:Z9 + Z9;
              Z7 := EM1:Z4;   // スロット番号
              Z7 := Z7 * 52 + 1000 + Z9;
              Z5 := EM16.L:Z9;
              Z5 := Z5 * 4 + Z7 + 4;
              EM1.L:Z2 := EM1.L:Z5;
              EM0:Z2 := EM0:Z5;
              Z2 := 2 * 4 + EM32:Z9 + Z9;   // R[2] に値
              Z7 := EM2:Z4;   // スロット番号
              Z7 := Z7 * 52 + 1000 + Z9;
              Z5 := EM16.L:Z9;
              Z5 := Z5 * 4 + Z7 + 4;
              EM1.L:Z2 := EM1.L:Z5;
              EM0:Z2 := EM0:Z5;
              EM37:Z9 := 2;
            ELSIF EM5:Z3 = 2 THEN
              // a.each はその位置の要素を渡す。レシーバの配列は R[0] に残っている
              Z4 := 0 + EM32:Z9 + Z9;
              // **スロット番号は 2 つ目のスクラッチへ。** 1 つ目には反復の添字が
              // 載っていて、これから要素の位置を出すのに使う
              Z7 := EM1.L:Z4;   // スロット番号
              Z7 := Z7 * 52 + 1000 + Z9;
              Z5 := EM16.L:Z9;
              Z5 := Z5 * 4 + Z7 + 4;
              EM1.L:Z2 := EM1.L:Z5;
              EM0:Z2 := EM0:Z5;
              EM37:Z9 := 1;
            ELSE
              // times / upto は添字を渡す
              EM1.L:Z2 := EM16.L:Z9;
              EM0:Z2 := 4;
              EM37:Z9 := 1;
            END_IF;
            EM0:Z9 := 0;
          ELSE
            // 反復の終わり。R[0] にはレシーバが残っており、それが呼び出しの値になる
            EM31:Z9 := EM31:Z9 - 1;
            // 外した段がそのまま戻り先。減らした後なので top_frame_expr ではない
            Z3 := EM31:Z9 * 10 + 376 + Z9;
            EM0:Z9 := EM0:Z3;
            Z5 := EM1:Z3;
            EM32:Z9 := EM2:Z3;
            EM30:Z9 := Z5;
            // IREP テーブルから実行中の irep の情報を写す
            Z1 := Z5 * 8 + EM38:Z9;
            EM33:Z9 := FM0:Z1;
            EM10:Z9 := FM1:Z1;
            EM34:Z9 := FM2:Z1;
            EM35:Z9 := FM3:Z1;
            EM11:Z9 := FM4:Z1;
          END_IF;
        ELSE
          // R[a] を R[0] へ写す。R[0] は呼んだ側の R[a] と同じ場所なので
          // これで戻り値が呼び出し元から見える位置に入る
          Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
          Z2 := 0 + EM32:Z9 + Z9;
          EM1.L:Z2 := EM1.L:Z1;
          EM0:Z2 := EM0:Z1;
          EM31:Z9 := EM31:Z9 - 1;
          // 外した段がそのまま戻り先。減らした後なので top_frame_expr ではない
          Z3 := EM31:Z9 * 10 + 376 + Z9;
          EM0:Z9 := EM0:Z3;
          Z5 := EM1:Z3;
          EM32:Z9 := EM2:Z3;
          EM30:Z9 := Z5;
          // IREP テーブルから実行中の irep の情報を写す
          Z1 := Z5 * 8 + EM38:Z9;
          EM33:Z9 := FM0:Z1;
          EM10:Z9 := FM1:Z1;
          EM34:Z9 := FM2:Z1;
          EM35:Z9 := FM3:Z1;
          EM11:Z9 := FM4:Z1;
        END_IF;
      END_IF;

    ELSIF EM6:Z9 = 58 THEN
      // OP_BREAK (B): 反復を打ち切って R[a] を返す
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      IF EM31:Z9 = 0 THEN
        // 反復の外での break
        EM1:Z9 := 3;
        EM2:Z9 := 9;
        EXIT;
      END_IF;
      Z3 := (EM31:Z9 - 1) * 10 + 376 + Z9;
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
      Z3 := EM31:Z9 * 10 + 376 + Z9;
      EM0:Z9 := EM0:Z3;
      Z5 := EM1:Z3;
      EM32:Z9 := EM2:Z3;
      EM30:Z9 := Z5;
      // IREP テーブルから実行中の irep の情報を写す
      Z1 := Z5 * 8 + EM38:Z9;
      EM33:Z9 := FM0:Z1;
      EM10:Z9 := FM1:Z1;
      EM34:Z9 := FM2:Z1;
      EM35:Z9 := FM3:Z1;
      EM11:Z9 := FM4:Z1;

    ELSIF EM6:Z9 = 60 THEN
      // OP_ADD (B): R[a] = R[a] + R[a+1]
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
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
            IF EM39:Z9 >= 16 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 10;
              EXIT;
            END_IF;
            Z4 := EM1.L:Z1;
            Z4 := Z4 * 52 + 1000 + Z9;
            EM16.L:Z9 := EM0:Z4;
            Z5 := EM1.L:Z2;
            Z5 := Z5 * 52 + 1000 + Z9;
            EM18.L:Z9 := EM0:Z5;
            // 1 スロットに収まること
            Z6 := EM16.L:Z9 + EM18.L:Z9;
            IF Z6 > 96 THEN
              EM1:Z9 := 3;
              EM2:Z9 := 10;
              EXIT;
            END_IF;
            // 新しいスロットへ左側をワード単位で写す。並びが同じなのでそのまま
            Z3 := EM39:Z9 * 52 + 1000 + Z9;
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
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      IF EM0:Z1 = 5 THEN
        EM1.F:Z1 := EM1.F:Z1 + EM8:Z9;
        EM0:Z1 := 5;
      ELSE
        EM1.L:Z1 := EM1.L:Z1 + EM8:Z9;
        EM0:Z1 := 4;
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
