// =======================================
// faRuby VM - オペコード 0x10 - 0x1E
// =======================================
// 【自動生成】このファイルを直接編集しないでください。
//   定義: tools/opcode_table.rb
//   生成: tools/kvs_generator.rb  (rake vm_core)
//   編集した場合 test_kvs_generator.rb が失敗します。
//
// ラダーでの置き場所: 内側 FOR の中 (3 番目の群)
// 並び順と役割は vm_02_prologue.st の先頭にあります。

// 担当外の番号はここで素通りする。**判定はループの外に置く。**
// 見るのは上限だけ。16 未満は手前の群が実行して
// 65535 で潰しているので、ここには届かない
IF EM54:Z9 <= 30 THEN

  // 後ろの群がもう一度実行しないように潰す。**本体より先に置く。**
  // 本体は途中で BREAK することがあり、後ろに置くと通らない
  EM54:Z9 := 65535;

  // BREAK の相手 (1 回だけ回る)。抜けるとこのスクリプトが終わる
  FOR EM20:Z9 := 1 TO 1 DO

    IF EM6:Z9 = 16 THEN
      // OP_LOADSYM (BB): R[a] = symbols[b] (シンボル)
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
        // デバイス名や変数名はシンボルとして扱えない
        EM1:Z9 := 3;
        EM2:Z9 := 3;
        EXIT;
      END_IF;
      Z3 := Z3 + 1;
      Z6 := FM0:Z3;   // シンボルの通し番号
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1.L:Z1 := Z6;
      EM0:Z1 := 6;

    ELSIF EM6:Z9 = 17 THEN
      // OP_LOADNIL (B): R[a] = nil
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1.L:Z1 := 0;
      EM0:Z1 := 1;

    ELSIF EM6:Z9 = 18 THEN
      // OP_LOADSELF (B): R[a] = self (main)
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1.L:Z1 := 0;
      EM0:Z1 := 10;

    ELSIF EM6:Z9 = 19 THEN
      // OP_LOADT (B): R[a] = true
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1.L:Z1 := 1;
      EM0:Z1 := 3;

    ELSIF EM6:Z9 = 20 THEN
      // OP_LOADF (B): R[a] = false
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      EM1.L:Z1 := 0;
      EM0:Z1 := 2;

    ELSIF EM6:Z9 = 21 THEN
      // OP_GETGV (BB): R[a] = global[symbols[b]]
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      // シンボル表参照 (4ワード/エントリ)
      Z3 := EM8:Z9 * 4 + EM35:Z9;
      Z4 := Z3 + 1;
      Z5 := FM0:Z3;
      Z6 := FM0:Z4;
      Z7 := Z3 + 2;
      Z8 := FM0:Z7;
      Z7 := Z3 + 3;
      Z1 := FM0:Z7;   // シンボル種別
      // レジスタアドレス
      Z2 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      // 種別で 4 つに分ける。いちばん多い普通のデバイスがここで決まる
      IF Z1 = 0 THEN
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
            EM1.L:Z2 := EM0.L:Z6;
            EM0:Z2 := 4;
          ELSIF Z8 = 1 THEN
            EM1.L:Z2 := EM0.U:Z6;
            EM0:Z2 := 4;
          ELSIF Z8 = 3 THEN
            EM1.L:Z2 := EM0.D:Z6;
            EM0:Z2 := 4;
          ELSIF Z8 = 4 THEN
            EM1.F:Z2 := EM0.F:Z6;
            EM0:Z2 := 5;
          ELSE
            EM1.L:Z2 := EM0.S:Z6;
            EM0:Z2 := 4;
          END_IF;
        ELSIF Z5 = 1 THEN
          IF Z8 = 2 THEN
            EM1.L:Z2 := DM0.L:Z6;
            EM0:Z2 := 4;
          ELSIF Z8 = 1 THEN
            EM1.L:Z2 := DM0.U:Z6;
            EM0:Z2 := 4;
          ELSIF Z8 = 3 THEN
            EM1.L:Z2 := DM0.D:Z6;
            EM0:Z2 := 4;
          ELSIF Z8 = 4 THEN
            EM1.F:Z2 := DM0.F:Z6;
            EM0:Z2 := 5;
          ELSE
            EM1.L:Z2 := DM0.S:Z6;
            EM0:Z2 := 4;
          END_IF;
        ELSIF Z5 = 2 THEN
          IF Z8 = 2 THEN
            EM1.L:Z2 := ZF0.L:Z6;
            EM0:Z2 := 4;
          ELSIF Z8 = 1 THEN
            EM1.L:Z2 := ZF0.U:Z6;
            EM0:Z2 := 4;
          ELSIF Z8 = 3 THEN
            EM1.L:Z2 := ZF0.D:Z6;
            EM0:Z2 := 4;
          ELSIF Z8 = 4 THEN
            EM1.F:Z2 := ZF0.F:Z6;
            EM0:Z2 := 5;
          ELSE
            EM1.L:Z2 := ZF0.S:Z6;
            EM0:Z2 := 4;
          END_IF;
        ELSIF Z5 = 3 THEN
          IF Z8 = 5 THEN
            IF R0:Z6 THEN
              EM1.L:Z2 := 1;
              EM0:Z2 := 3;
            ELSE
              EM1.L:Z2 := 0;
              EM0:Z2 := 2;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              EM1.L:Z2 := R0.L:Z6;
              EM0:Z2 := 4;
            ELSIF Z8 = 1 THEN
              EM1.L:Z2 := R0.U:Z6;
              EM0:Z2 := 4;
            ELSIF Z8 = 3 THEN
              EM1.L:Z2 := R0.D:Z6;
              EM0:Z2 := 4;
            ELSIF Z8 = 4 THEN
              EM1.F:Z2 := R0.F:Z6;
              EM0:Z2 := 5;
            ELSE
              EM1.L:Z2 := R0.S:Z6;
              EM0:Z2 := 4;
            END_IF;
          END_IF;
        ELSIF Z5 = 4 THEN
          IF Z8 = 5 THEN
            IF MR0:Z6 THEN
              EM1.L:Z2 := 1;
              EM0:Z2 := 3;
            ELSE
              EM1.L:Z2 := 0;
              EM0:Z2 := 2;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              EM1.L:Z2 := MR0.L:Z6;
              EM0:Z2 := 4;
            ELSIF Z8 = 1 THEN
              EM1.L:Z2 := MR0.U:Z6;
              EM0:Z2 := 4;
            ELSIF Z8 = 3 THEN
              EM1.L:Z2 := MR0.D:Z6;
              EM0:Z2 := 4;
            ELSIF Z8 = 4 THEN
              EM1.F:Z2 := MR0.F:Z6;
              EM0:Z2 := 5;
            ELSE
              EM1.L:Z2 := MR0.S:Z6;
              EM0:Z2 := 4;
            END_IF;
          END_IF;
        ELSIF Z5 = 5 THEN
          IF Z8 = 5 THEN
            IF B0:Z6 THEN
              EM1.L:Z2 := 1;
              EM0:Z2 := 3;
            ELSE
              EM1.L:Z2 := 0;
              EM0:Z2 := 2;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              EM1.L:Z2 := B0.L:Z6;
              EM0:Z2 := 4;
            ELSIF Z8 = 1 THEN
              EM1.L:Z2 := B0.U:Z6;
              EM0:Z2 := 4;
            ELSIF Z8 = 3 THEN
              EM1.L:Z2 := B0.D:Z6;
              EM0:Z2 := 4;
            ELSIF Z8 = 4 THEN
              EM1.F:Z2 := B0.F:Z6;
              EM0:Z2 := 5;
            ELSE
              EM1.L:Z2 := B0.S:Z6;
              EM0:Z2 := 4;
            END_IF;
          END_IF;
        ELSIF Z5 = 6 THEN
          IF Z8 = 5 THEN
            IF LR0:Z6 THEN
              EM1.L:Z2 := 1;
              EM0:Z2 := 3;
            ELSE
              EM1.L:Z2 := 0;
              EM0:Z2 := 2;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              EM1.L:Z2 := LR0.L:Z6;
              EM0:Z2 := 4;
            ELSIF Z8 = 1 THEN
              EM1.L:Z2 := LR0.U:Z6;
              EM0:Z2 := 4;
            ELSIF Z8 = 3 THEN
              EM1.L:Z2 := LR0.D:Z6;
              EM0:Z2 := 4;
            ELSIF Z8 = 4 THEN
              EM1.F:Z2 := LR0.F:Z6;
              EM0:Z2 := 5;
            ELSE
              EM1.L:Z2 := LR0.S:Z6;
              EM0:Z2 := 4;
            END_IF;
          END_IF;
        ELSE
          EM1:Z9 := 3;
          EM2:Z9 := 21;
          EXIT;
        END_IF;
      ELSIF Z1 = 5 THEN
        // 汎用グローバルは値スロット。型タグごと写す
        Z3 := Z6;
        EM1.L:Z2 := EM1.L:Z3;
        EM0:Z2 := EM0:Z3;
      ELSIF Z1 = 1 THEN
        // デバイス族。読み書きせず参照値を作る ($DM[i] の $DM の部分)
        EM1:Z2 := Z6;   // ベースアドレス
        EM2:Z2 := Z5 + Z8 * 16;   // 種別 + 幅
        EM0:Z2 := 11;
      ELSE
        // 文字列を読めるのは EM / DM / ZF だけ
        // **この検査は FOR の外に置く。** 中の BREAK は FOR を抜けるだけで
        // 命令ループから出られず、エラーを書いてもそのまま走り続ける
        IF Z5 > 2 THEN
          EM1:Z9 := 3;
          EM2:Z9 := 21;
          EXIT;
        END_IF;
        EM44:Z9 := Z8 / 16;   // 桁数 = バイト数
        IF EM44:Z9 = 0 THEN
          // 桁の無い T は読めない。長さが決まらない
          EM1:Z9 := 3;
          EM2:Z9 := 21;
          EXIT;
        END_IF;
        IF EM44:Z9 > 96 THEN
          // 1 スロットに収まらない桁数
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
        Z3 := EM39:Z9 * 50 + 1000 + Z9;
        EM0:Z3 := EM44:Z9;
        // ワード単位で写す。並びが同じなので詰め替えは要らない
        EM45:Z9 := EM44:Z9 + 1;
        EM45:Z9 := EM45:Z9 / 2;   // ワード数
        IF EM45:Z9 > 0 THEN
          EM45:Z9 := EM45:Z9 - 1;
          FOR EM42:Z9 := 0 TO EM45:Z9 DO
            Z4 := EM42:Z9 + Z6;   // デバイスの位置
            // ワードデバイスから 1 ワード。種別は FOR に入る前に検査済み
            IF Z5 = 0 THEN
              Z7 := EM0.U:Z4;
            ELSIF Z5 = 1 THEN
              Z7 := DM0.U:Z4;
            ELSE
              Z7 := ZF0.U:Z4;
            END_IF;
            Z4 := EM42:Z9 + Z3 + 2;
            EM0:Z4 := Z7;
          END_FOR;
        END_IF;
        // 桁が奇数なら最後のワードの下位バイトは桁の外。0 にして中身に混ぜない
        // 残すと同じ中身どうしの == がワード単位の比較で外れる
        EM45:Z9 := EM44:Z9 / 2;
        EM43:Z9 := EM45:Z9 * 2;
        IF EM44:Z9 <> EM43:Z9 THEN
          Z4 := EM45:Z9 + Z3 + 2;
          Z7 := EM0:Z4;
          Z7 := Z7 / 256;
          EM0:Z4 := Z7 * 256;
        END_IF;
        EM1.L:Z2 := EM39:Z9;   // スロット番号
        EM0:Z2 := 7;
        EM39:Z9 := EM39:Z9 + 1;
      END_IF;

    ELSIF EM6:Z9 = 22 THEN
      // OP_SETGV (BB): global[symbols[b]] = R[a]
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      // シンボル表参照 (4ワード/エントリ)
      Z3 := EM8:Z9 * 4 + EM35:Z9;
      Z4 := Z3 + 1;
      Z5 := FM0:Z3;
      Z6 := FM0:Z4;
      Z7 := Z3 + 2;
      Z8 := FM0:Z7;
      Z7 := Z3 + 3;
      Z1 := FM0:Z7;   // シンボル種別
      // レジスタアドレス
      Z2 := EM7:Z9 * 4 + EM32:Z9 + Z9;
      IF Z1 = 5 THEN
        // 汎用グローバルは値スロット。型タグごと写す
        Z3 := Z6;
        EM1.L:Z3 := EM1.L:Z2;
        EM0:Z3 := EM0:Z2;
      ELSIF Z1 = 1 THEN
        // デバイス族そのものへの代入 ($DM = 1) は意味を持たない
        EM1:Z9 := 3;
        EM2:Z9 := 22;
        EXIT;
      ELSIF EM0:Z2 = 7 THEN
        // 文字列を書けるのは EM / DM / ZF だけ
        // **この検査は FOR の外に置く。** 中の BREAK は FOR を抜けるだけで
        // 命令ループから出られず、エラーを書いてもそのまま走り続ける
        IF Z5 > 2 THEN
          EM1:Z9 := 3;
          EM2:Z9 := 22;
          EXIT;
        END_IF;
        // 桁数。0 なら終端付き
        Z7 := Z8 / 16;
        // 文字列スロットの見出し
        Z4 := EM1.L:Z2;
        Z4 := Z4 * 50 + 1000 + Z9;
        EM18.L:Z9 := EM0:Z4;   // バイト数
        // 書く長さと埋めるバイトを決める
        IF Z7 = 0 THEN
          // 終端付き。バイト列 + 0
          EM16.L:Z9 := EM18.L:Z9 + 1;
          Z8 := 0;
        ELSE
          // 固定長。余りは FARUBY_STR_FILL
          EM16.L:Z9 := Z7;
          Z8 := EM41:Z9;
        END_IF;
        // 中身の長さ。桁からはみ出す分は切り詰める
        IF EM18.L:Z9 > EM16.L:Z9 THEN
          EM18.L:Z9 := EM16.L:Z9;
        END_IF;
        // ワード数。奇数バイトなら最後のワードの下位バイトは埋めるバイト
        Z2 := EM16.L:Z9 + 1;
        Z2 := Z2 / 2;
        IF Z2 > 0 THEN
          Z2 := Z2 - 1;
          FOR Z3 := 0 TO Z2 DO
            Z1 := Z3 * 2;   // 先頭バイトの位置
            Z7 := Z1 + 1;
            IF Z7 < EM18.L:Z9 THEN
              // 2 バイトとも中身。並びが同じなのでそのまま写す
              Z7 := Z3 + Z4 + 2;
              Z7 := EM0:Z7;
            ELSE
              // 末尾の半端なワード。バイトごとに決める
              Z7 := 0;
              IF Z1 < EM18.L:Z9 THEN
                Z7 := Z3 + Z4 + 2;
                Z7 := EM0:Z7;
                Z7 := Z7 / 256;   // 上位バイトだけ中身
              ELSE
                IF Z1 < EM16.L:Z9 THEN
                  Z7 := Z8;
                END_IF;
              END_IF;
              Z7 := Z7 * 256;
              Z1 := Z1 + 1;
              IF Z1 < EM16.L:Z9 THEN
                Z7 := Z7 + Z8;
              END_IF;
            END_IF;
            // ワードデバイスへ 1 ワード。種別は FOR に入る前に検査済み
            Z1 := Z3 + Z6;
            IF Z5 = 0 THEN
              EM0.U:Z1 := Z7;
            ELSIF Z5 = 1 THEN
              DM0.U:Z1 := Z7;
            ELSE
              ZF0.U:Z1 := Z7;
            END_IF;
          END_FOR;
        END_IF;
      ELSIF EM0:Z2 = 8 THEN
        // **検査はすべて FOR の外に置く。** 中の BREAK は FOR を抜けるだけで
        // 命令ループから出られず、エラーを書いてもそのまま走り続ける
        // 個別ビットには書けない。1 要素が何ビットか決まらない
        IF Z8 = 5 THEN
          EM1:Z9 := 3;
          EM2:Z9 := 22;
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
          EM2:Z9 := 22;
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
        // スロットの見出しと書き先の先頭。どちらもループの中で動かさない
        Z4 := EM1.L:Z2;
        Z4 := Z4 * 50 + 1000 + Z9;
        EM44:Z9 := Z6;   // 書き先の先頭
        EM18.L:Z9 := EM0:Z4;   // 要素数
        // 数値でない要素があった印。FOR を出てから判定する
        EM43:Z9 := 0;
        IF EM18.L:Z9 > 0 THEN
          Z7 := EM18.L:Z9;
          Z7 := Z7 - 1;
          FOR EM42:Z9 := 0 TO Z7 DO
            Z3 := EM42:Z9 * 4 + Z4 + 2;
            EM47:Z9 := 0;
            IF EM0:Z3 >= 4 THEN
              IF EM0:Z3 <= 5 THEN
                EM47:Z9 := 1;
              END_IF;
            END_IF;
            IF EM47:Z9 = 0 THEN
              EM43:Z9 := 1;
            ELSE
              Z6 := EM42:Z9 * EM45:Z9 + EM44:Z9;
              // レジスタの値を書き込み先の幅に合わせて変換する
              // 使う側の形だけを作る。Infinity や NaN の整数変換は
              // 浮動小数点フォーマット異常になるため、.F 書き込みでは行わない
              IF Z8 = 4 THEN
                IF EM0:Z3 = 5 THEN
                  EM18.F:Z9 := EM1.F:Z3;
                ELSE
                  EM18.F:Z9 := EM1.L:Z3;   // 整数→実数
                END_IF;
              ELSE
                IF EM0:Z3 = 5 THEN
                  EM16.L:Z9 := EM1.F:Z3;   // 実数→整数 (0方向へ切り捨て)
                ELSE
                  EM16.L:Z9 := EM1.L:Z3;
                END_IF;
              END_IF;
              // デバイスタイプ別書き込み
              // ワードデバイス (EM, DM, ZF): Z8 (access_type) で幅を選ぶ
              //   2=.L(32bit符号付き)
              //   1=.U(16bit符号なし)
              //   3=.D(32bit符号なし)
              //   4=.F(実数)
              //   それ以外=.S(16bit符号付き/既定)
              // ビットデバイス (R, MR, B, LR): 非0→ON, 0→OFF
              //   true=1 / false=nil=0 なので値だけで判定できる
              IF Z5 = 0 THEN
                IF Z8 = 2 THEN
                  EM0.L:Z6 := EM16.L:Z9;
                ELSIF Z8 = 1 THEN
                  EM0.U:Z6 := EM16.L:Z9;
                ELSIF Z8 = 3 THEN
                  EM0.D:Z6 := EM16.L:Z9;
                ELSIF Z8 = 4 THEN
                  EM0.F:Z6 := EM18.F:Z9;
                ELSE
                  EM0.S:Z6 := EM16.L:Z9;
                END_IF;
              ELSIF Z5 = 1 THEN
                IF Z8 = 2 THEN
                  DM0.L:Z6 := EM16.L:Z9;
                ELSIF Z8 = 1 THEN
                  DM0.U:Z6 := EM16.L:Z9;
                ELSIF Z8 = 3 THEN
                  DM0.D:Z6 := EM16.L:Z9;
                ELSIF Z8 = 4 THEN
                  DM0.F:Z6 := EM18.F:Z9;
                ELSE
                  DM0.S:Z6 := EM16.L:Z9;
                END_IF;
              ELSIF Z5 = 2 THEN
                IF Z8 = 2 THEN
                  ZF0.L:Z6 := EM16.L:Z9;
                ELSIF Z8 = 1 THEN
                  ZF0.U:Z6 := EM16.L:Z9;
                ELSIF Z8 = 3 THEN
                  ZF0.D:Z6 := EM16.L:Z9;
                ELSIF Z8 = 4 THEN
                  ZF0.F:Z6 := EM18.F:Z9;
                ELSE
                  ZF0.S:Z6 := EM16.L:Z9;
                END_IF;
              ELSIF Z5 = 3 THEN
                IF Z8 = 5 THEN
                  IF EM16.L:Z9 <> 0 THEN
                    R0:Z6 := TRUE;
                  ELSE
                    R0:Z6 := FALSE;
                  END_IF;
                ELSE
                  IF Z8 = 2 THEN
                    R0.L:Z6 := EM16.L:Z9;
                  ELSIF Z8 = 1 THEN
                    R0.U:Z6 := EM16.L:Z9;
                  ELSIF Z8 = 3 THEN
                    R0.D:Z6 := EM16.L:Z9;
                  ELSIF Z8 = 4 THEN
                    R0.F:Z6 := EM18.F:Z9;
                  ELSE
                    R0.S:Z6 := EM16.L:Z9;
                  END_IF;
                END_IF;
              ELSIF Z5 = 4 THEN
                IF Z8 = 5 THEN
                  IF EM16.L:Z9 <> 0 THEN
                    MR0:Z6 := TRUE;
                  ELSE
                    MR0:Z6 := FALSE;
                  END_IF;
                ELSE
                  IF Z8 = 2 THEN
                    MR0.L:Z6 := EM16.L:Z9;
                  ELSIF Z8 = 1 THEN
                    MR0.U:Z6 := EM16.L:Z9;
                  ELSIF Z8 = 3 THEN
                    MR0.D:Z6 := EM16.L:Z9;
                  ELSIF Z8 = 4 THEN
                    MR0.F:Z6 := EM18.F:Z9;
                  ELSE
                    MR0.S:Z6 := EM16.L:Z9;
                  END_IF;
                END_IF;
              ELSIF Z5 = 5 THEN
                IF Z8 = 5 THEN
                  IF EM16.L:Z9 <> 0 THEN
                    B0:Z6 := TRUE;
                  ELSE
                    B0:Z6 := FALSE;
                  END_IF;
                ELSE
                  IF Z8 = 2 THEN
                    B0.L:Z6 := EM16.L:Z9;
                  ELSIF Z8 = 1 THEN
                    B0.U:Z6 := EM16.L:Z9;
                  ELSIF Z8 = 3 THEN
                    B0.D:Z6 := EM16.L:Z9;
                  ELSIF Z8 = 4 THEN
                    B0.F:Z6 := EM18.F:Z9;
                  ELSE
                    B0.S:Z6 := EM16.L:Z9;
                  END_IF;
                END_IF;
              ELSIF Z5 = 6 THEN
                IF Z8 = 5 THEN
                  IF EM16.L:Z9 <> 0 THEN
                    LR0:Z6 := TRUE;
                  ELSE
                    LR0:Z6 := FALSE;
                  END_IF;
                ELSE
                  IF Z8 = 2 THEN
                    LR0.L:Z6 := EM16.L:Z9;
                  ELSIF Z8 = 1 THEN
                    LR0.U:Z6 := EM16.L:Z9;
                  ELSIF Z8 = 3 THEN
                    LR0.D:Z6 := EM16.L:Z9;
                  ELSIF Z8 = 4 THEN
                    LR0.F:Z6 := EM18.F:Z9;
                  ELSE
                    LR0.S:Z6 := EM16.L:Z9;
                  END_IF;
                END_IF;
              ELSE
                // 呼ぶ側が種別を確かめている。ここへは来ない
              END_IF;
            END_IF;
          END_FOR;
        END_IF;
        IF EM43:Z9 = 1 THEN
          // 数値でない要素があった。入れ子の書き出し方は決めていない
          EM1:Z9 := 3;
          EM2:Z9 := 22;
          EXIT;
        END_IF;
      ELSIF EM0:Z2 = 9 THEN
        // ハッシュはデバイスへ写せない。鍵の並べ方が決まらない
        EM1:Z9 := 3;
        EM2:Z9 := 22;
        EXIT;
      ELSE
        IF Z8 >= 6 THEN
          // 文字列の桁 (T) に文字列以外を書こうとした
          EM1:Z9 := 3;
          EM2:Z9 := 22;
          EXIT;
        END_IF;
        // レジスタの値を書き込み先の幅に合わせて変換する
        // 使う側の形だけを作る。Infinity や NaN の整数変換は
        // 浮動小数点フォーマット異常になるため、.F 書き込みでは行わない
        IF Z8 = 4 THEN
          IF EM0:Z2 = 5 THEN
            EM18.F:Z9 := EM1.F:Z2;
          ELSE
            EM18.F:Z9 := EM1.L:Z2;   // 整数→実数
          END_IF;
        ELSE
          IF EM0:Z2 = 5 THEN
            EM16.L:Z9 := EM1.F:Z2;   // 実数→整数 (0方向へ切り捨て)
          ELSE
            EM16.L:Z9 := EM1.L:Z2;
          END_IF;
        END_IF;
        // デバイスタイプ別書き込み
        // ワードデバイス (EM, DM, ZF): Z8 (access_type) で幅を選ぶ
        //   2=.L(32bit符号付き)
        //   1=.U(16bit符号なし)
        //   3=.D(32bit符号なし)
        //   4=.F(実数)
        //   それ以外=.S(16bit符号付き/既定)
        // ビットデバイス (R, MR, B, LR): 非0→ON, 0→OFF
        //   true=1 / false=nil=0 なので値だけで判定できる
        IF Z5 = 0 THEN
          IF Z8 = 2 THEN
            EM0.L:Z6 := EM16.L:Z9;
          ELSIF Z8 = 1 THEN
            EM0.U:Z6 := EM16.L:Z9;
          ELSIF Z8 = 3 THEN
            EM0.D:Z6 := EM16.L:Z9;
          ELSIF Z8 = 4 THEN
            EM0.F:Z6 := EM18.F:Z9;
          ELSE
            EM0.S:Z6 := EM16.L:Z9;
          END_IF;
        ELSIF Z5 = 1 THEN
          IF Z8 = 2 THEN
            DM0.L:Z6 := EM16.L:Z9;
          ELSIF Z8 = 1 THEN
            DM0.U:Z6 := EM16.L:Z9;
          ELSIF Z8 = 3 THEN
            DM0.D:Z6 := EM16.L:Z9;
          ELSIF Z8 = 4 THEN
            DM0.F:Z6 := EM18.F:Z9;
          ELSE
            DM0.S:Z6 := EM16.L:Z9;
          END_IF;
        ELSIF Z5 = 2 THEN
          IF Z8 = 2 THEN
            ZF0.L:Z6 := EM16.L:Z9;
          ELSIF Z8 = 1 THEN
            ZF0.U:Z6 := EM16.L:Z9;
          ELSIF Z8 = 3 THEN
            ZF0.D:Z6 := EM16.L:Z9;
          ELSIF Z8 = 4 THEN
            ZF0.F:Z6 := EM18.F:Z9;
          ELSE
            ZF0.S:Z6 := EM16.L:Z9;
          END_IF;
        ELSIF Z5 = 3 THEN
          IF Z8 = 5 THEN
            IF EM16.L:Z9 <> 0 THEN
              R0:Z6 := TRUE;
            ELSE
              R0:Z6 := FALSE;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              R0.L:Z6 := EM16.L:Z9;
            ELSIF Z8 = 1 THEN
              R0.U:Z6 := EM16.L:Z9;
            ELSIF Z8 = 3 THEN
              R0.D:Z6 := EM16.L:Z9;
            ELSIF Z8 = 4 THEN
              R0.F:Z6 := EM18.F:Z9;
            ELSE
              R0.S:Z6 := EM16.L:Z9;
            END_IF;
          END_IF;
        ELSIF Z5 = 4 THEN
          IF Z8 = 5 THEN
            IF EM16.L:Z9 <> 0 THEN
              MR0:Z6 := TRUE;
            ELSE
              MR0:Z6 := FALSE;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              MR0.L:Z6 := EM16.L:Z9;
            ELSIF Z8 = 1 THEN
              MR0.U:Z6 := EM16.L:Z9;
            ELSIF Z8 = 3 THEN
              MR0.D:Z6 := EM16.L:Z9;
            ELSIF Z8 = 4 THEN
              MR0.F:Z6 := EM18.F:Z9;
            ELSE
              MR0.S:Z6 := EM16.L:Z9;
            END_IF;
          END_IF;
        ELSIF Z5 = 5 THEN
          IF Z8 = 5 THEN
            IF EM16.L:Z9 <> 0 THEN
              B0:Z6 := TRUE;
            ELSE
              B0:Z6 := FALSE;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              B0.L:Z6 := EM16.L:Z9;
            ELSIF Z8 = 1 THEN
              B0.U:Z6 := EM16.L:Z9;
            ELSIF Z8 = 3 THEN
              B0.D:Z6 := EM16.L:Z9;
            ELSIF Z8 = 4 THEN
              B0.F:Z6 := EM18.F:Z9;
            ELSE
              B0.S:Z6 := EM16.L:Z9;
            END_IF;
          END_IF;
        ELSIF Z5 = 6 THEN
          IF Z8 = 5 THEN
            IF EM16.L:Z9 <> 0 THEN
              LR0:Z6 := TRUE;
            ELSE
              LR0:Z6 := FALSE;
            END_IF;
          ELSE
            IF Z8 = 2 THEN
              LR0.L:Z6 := EM16.L:Z9;
            ELSIF Z8 = 1 THEN
              LR0.U:Z6 := EM16.L:Z9;
            ELSIF Z8 = 3 THEN
              LR0.D:Z6 := EM16.L:Z9;
            ELSIF Z8 = 4 THEN
              LR0.F:Z6 := EM18.F:Z9;
            ELSE
              LR0.S:Z6 := EM16.L:Z9;
            END_IF;
          END_IF;
        ELSE
          EM1:Z9 := 3;
          EM2:Z9 := 22;
          EXIT;
        END_IF;
      END_IF;

    ELSIF EM6:Z9 = 30 THEN
      // OP_SETCONST (BB): FARUBY_ の設定なら VM 状態へ書く
      Z1 := EM0:Z9 + EM33:Z9;
      EM7:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z1 := EM0:Z9 + EM33:Z9;
      EM8:Z9 := FM0:Z1;
      EM0:Z9 := EM0:Z9 + 1;
      Z3 := EM8:Z9 * 4 + EM35:Z9;
      Z4 := Z3 + 3;
      Z5 := FM0:Z4;   // シンボル種別
      IF Z5 = 3 THEN
        Z6 := FM0:Z3;   // 設定番号
        Z1 := EM7:Z9 * 4 + EM32:Z9 + Z9;
        IF Z6 = 1 THEN
          // 固定長でデバイスへ書いたときの余りを埋めるバイト
          EM41:Z9 := EM1.L:Z1;
        END_IF;
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
