# faRuby

PLC 上で Ruby を動作させる実験的プロジェクトです。

名称は **FA (Factory Automation) + Ruby** に由来します。

| 用途 | 表記 |
|------|------|
| 表示名 | `faRuby` |
| Ruby モジュール | `FaRuby` |
| リポジトリ・設定ファイル | `faruby` |

## 概要

mruby/c の仮想マシン (VM) を PLC のスクリプト言語でゼロから実装し、Ruby で書いたプログラムを PLC 上で実行できるようにします。

### 対応 PLC

- Keyence KV シリーズ (KV スクリプトで実装) - 開発中
- 三菱電機 MELSEC シリーズ - 予定

## システム構成

```
[PC側]                              [PLC側 (Keyence KV)]
Ruby ソース (.rb)
  | mrbc (mruby コンパイラ)
  v
バイトコード (.mrb, RITE形式)
  | mrb_parser.rb (解析)
  | plc_codegen.rb (変換)
  v
EM レジスタ値リスト ──通信──>  EM メモリに格納
                                  |
                                  v
                                KV スクリプト VM
                                (fetch-decode-execute)
                                  |
                                  v
                                実行結果 (EM レジスタ)
```

## ディレクトリ構成

```
faruby/
├── tools/               PC側ツール (Ruby)
├── simulator/           PC側 VM シミュレータ
├── plc/keyence/         KV スクリプト VM (生成物)
├── test/                テスト
├── doc/                 ドキュメント
├── faruby_default.yml   既定設定 (リポジトリに含む)
└── faruby.yml           環境ごとの設定 (git 管理外)
```

## セットアップ

### 前提条件

- Ruby 3.0 以上
- mruby 3.3.0 (mrbc コンパイラを使用)
- [plc_access](https://github.com/ito-soft-design/plc_access) gem (PLC 通信用)

### mruby のビルド

```bash
git clone https://github.com/mruby/mruby.git -b 3.3.0
cd mruby
rake
```

ビルド後、`mruby/build/host/bin/mrbc` が使用できるようになります。

### 依存 gem のインストール

```bash
bundle install
```

### 設定ファイル

`faruby.yml.example` をコピーして、環境に合わせて編集してください。

```bash
cp faruby.yml.example faruby.yml
```

```yaml
plc:
  protocol: keyence_kv
  host: 192.168.0.10     # PLC の IP アドレス
  port: 8501

mrbc:
  path: /path/to/mrbc    # mrbc コンパイラのパス

vm:
  steps_per_cycle: 50     # 1スキャンあたりの実行命令数
```

設定は 2 層になっています。`faruby.yml` に書いた項目だけが `faruby_default.yml`
の既定値を上書きし、書かなかった項目は既定値のまま残ります。既定値の一覧と
説明は [faruby_default.yml](faruby_default.yml) にあります。

### メモリ配置

faRuby は PLC のデバイス領域を連続した 1 ブロックとして使用します。ラダーが
使用していない領域を割り当ててください。重なると双方が壊れます。

```yaml
memory:
  device: EM      # デバイス種別
  base: 20000     # 領域の先頭アドレス
  instances: 2    # 同時に実行するインスタンス数
  align: 1000     # ブロックサイズをこの倍数に切り上げる
```

既定では EM20000-EM29999 を 5000 ワードずつ 2 ブロックに分けて使用します。
内訳は `rake console` の `memmap` コマンドで確認できます。

配置を変えたら `rake vm_core` で KV スクリプトを再生成し、KV Studio に取り込んで
PLC へ転送し直してください。アドレスは生成されたスクリプトに定数として
焼き込まれるためです。

## 使い方

### コンソールの起動

```bash
rake console
```

対話型コンソールが起動し、PLC との通信が可能になります。

### コンソールコマンド

| コマンド | 説明 |
|---------|------|
| `compile <file.rb>` | Ruby ソースをコンパイル (.mrb 生成) |
| `load` | バイトコードを PLC に転送 |
| `run` | VM 実行開始 |
| `instance [n]` | 操作対象のインスタンスを表示 / 切り替え |
| `status` | VM 状態を表示 |
| `regs [count]` | レジスタ値を表示 |
| `vars` | グローバル変数の値を表示 |
| `dev <device> [value]` | デバイスの読み書き (例: `dev DM100`, `dev DM100 42`) |
| `stop` | VM 停止 |
| `reset` | VM リセット要求を送信 |
| `verify` | PLC メモリとバイナリを比較 |
| `memmap` | メモリ配置を表示 |
| `disasm` | バイトコード逆アセンブル表示 |
| `sim` | PC 上のシミュレータで実行 |
| `connect` | PLC 接続確認 |
| `help` | コマンド一覧 |
| `quit` | 終了 |

### 使用例

```
faruby> compile test.rb
faruby> load
faruby> verify
faruby> run
faruby> status
faruby> regs
```

### 複数プログラムの並行実行

インスタンスごとに独立した VM が動き、それぞれ別の Ruby プログラムを実行します。

```
faruby[0]> compile a.rb
faruby[0]> load
faruby[0]> run
faruby[0]> instance 1
faruby[1]> compile b.rb
faruby[1]> load
faruby[1]> run
```

`compile` / `load` / `run` / `status` / `regs` はすべて選択中のインスタンスに
対して働きます。数は `faruby.yml` の `memory.instances` で決まり、変更したら
`rake vm_core` で再生成して取り込み直します。

### グローバル変数による PLC デバイスの読み書き

`$` で始まる変数名がそのままデバイスを指します。

```ruby
$DM100 = 42          # DM100 に書き込み (16ビット符号付き)
$MR10 = 1            # ビットデバイスを ON
$total = $DM100 + 1  # デバイス名でない場合は汎用グローバル変数
```

ワードデバイスはアクセス幅を末尾で指定できます。既定は 16 ビット符号付きです。

| 表記 | 意味 | 占有 |
|------|------|------|
| `$DM100` | 16ビット符号付き | 1 ワード |
| `$DM100U` | 16ビット符号なし | 1 ワード |
| `$DM100L` | 32ビット符号付き | 2 ワード |
| `$DM100D` | 32ビット符号なし | 2 ワード |
| `$DM100F` | 単精度実数 | 2 ワード |

同じデバイスを異なる幅で参照すると領域が重なります。割り当ての管理は
プログラム作成者が行ってください。

ビットデバイスは `true` / `false` を返すので、そのまま条件に書けます。

```ruby
if $MR10
  $MR20 = true
end
```

ワードデバイスは整数です。Ruby では 0 も真なので、非ゼロ判定は
`if $DM100 != 0` と書いてください。

### PLC 側 VM の生成と取り込み

`plc/keyence/*.kvs` は [tools/opcode_table.rb](tools/opcode_table.rb) から生成されます。
直接編集しないでください。

```bash
rake vm_core
```

生成された `vm_core.kvs` と `vm_init.kvs` を KV Studio に取り込み、PLC へ転送します。
命令を追加・変更した場合や、メモリ配置を変えた場合はこの手順が必要です。

### テストの実行

```bash
rake test
```

PC 上で完結するテストです。16 ビット丸めやアクセス幅サフィックスの解釈は
KV スクリプトでしか起きないため、[test/ruby_programs/](test/ruby_programs/) の
プログラムを実機で実行して確認します。

## 現在の対応範囲

- 整数の四則演算、比較、代入
- `if` / `while` による分岐と繰り返し
- `nil` / `true` / `false` と整数の区別 (`if 0` は Ruby と同じく真)
- 実数 (単精度)。整数と混ざると Ruby と同じく実数になる
- グローバル変数と PLC デバイスの読み書き
- 複数プログラムの並行実行 (既定 2 インスタンス)

整数は 32 ビット符号付き、実数は IEEE754 単精度です。

メソッド定義・呼び出し、配列、文字列は未対応です。
`%` も未対応です (mruby ではメソッド呼び出しにコンパイルされるため)。

詳細は [doc/architecture.md](doc/architecture.md) を参照してください。

## ライセンス

MIT License
