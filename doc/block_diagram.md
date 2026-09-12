# システム構成ブロック図

```mermaid
block-beta
    columns 9

    block:pc:3
        columns 1
        pclabel["<b>PC (開発環境)</b>"]
        src["Ruby ソース (.rb)"]
        mrbc["mrbc (mruby コンパイラ)"]
        bin["バイトコード (.mrb / RITE形式)"]
        conv["解析・変換\nmrb_parser.rb / plc_codegen.rb"]
    end

    space:3

    block:plc:3
        columns 2
        plclabel["<b>PLC</b>"]:2
        ladder["ラダー\nプログラム"]
        vm["mruby/c VM"]
        var["可変領域\nVM状態・レジスタ\nスタック・変数\n(EM / D)"]
        fix["固定領域\nバイトコード\n定数プール・シンボル表\n(FM / ZR)"]
    end

    conv -- "Ethernet (plc_access)" --> fix

    style pclabel fill:transparent,stroke:none
    style plclabel fill:transparent,stroke:none
```

## 説明

- **PC 側**: Ruby ソースを `mrbc` でバイトコードにコンパイルし、
  `mrb_parser.rb` / `plc_codegen.rb` で PLC のレジスタ値に変換する。
- **通信**: 変換したレジスタ値を Ethernet 経由で PLC のメモリに書き込む。
- **PLC 側**: ラダープログラムと mruby/c VM が併存する。
  PC からコンパイル済みのバイトコードを受け取り、VM が Ruby プログラムを実行する。
  - **可変領域**: 実行中に変わるデータ (VM 状態、レジスタ、スタック、変数)。キーエンスは EM、三菱は D
  - **固定領域**: 実行中に変わらないデータ (バイトコード、定数プール、シンボル表)。キーエンスは FM (ZF バンク)、三菱は ZR

## コンソール操作

```mermaid
block-beta
    columns 9

    block:ops:3
        columns 1
        opslabel["<b>コンソール (PC)</b>"]
        build["compile / disasm\nコンパイル・逆アセンブル\n(PC 内で完結)"]
        xfer["load / verify\n転送・照合"]
        ctrl["run / stop / reset\n実行制御"]
        mon["status / regs / vars / dev\n監視・読み書き"]
    end

    space:3

    block:target:3
        columns 1
        tlabel["<b>PLC (VM)</b>"]
        code["バイトコード\n定数プール・シンボル表"]
        state["実行状態\nSTATUS / PC / エラー"]
        reg["レジスタ・変数\nデバイス"]
    end

    xfer -- "書き込み / 読み取り" --> code
    ctrl -- "制御" --> state
    mon -- "読み取り" --> reg

    style opslabel fill:transparent,stroke:none
    style tlabel fill:transparent,stroke:none
```

- **compile / disasm**: PC 内で完結する。Ruby ソースをコンパイルし、バイトコードを確認する
- **load / verify**: コンパイル結果を PLC メモリに書き込む。verify は書き込み後の照合
- **run / stop / reset**: VM の実行状態を制御する
- **status / regs / vars / dev**: VM の状態やレジスタ、デバイスの値を読み取る
