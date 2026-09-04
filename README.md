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

faRuby は PLC のデバイス領域を 2 つ使います。ラダーが使用していない領域を
割り当ててください。重なると双方が壊れます。

| 区分 | デバイス | 内容 |
|------|---------|------|
| 実行中に変わる | EM | VM状態・レジスタ・呼び出しスタック・メソッド表・グローバル変数 |
| 実行中に変わらない | FM (バンク 3) | バイトコード・定数プール・シンボル表・IREPテーブル |

```yaml
memory:
  device: EM        # 可変領域のデバイス種別
  base: 20000       # 可変領域の先頭アドレス
  instances: 2      # 同時に実行するインスタンス数
  align: 1000       # ブロックサイズをこの倍数に切り上げる
  fixed_base: 0     # 固定領域 (FM) の先頭アドレス
  fixed_align: 1000
```

既定では EM20000-EM21999 を 1000 ワードずつ、FM0-FM9999 を 5000 ワードずつ
2 ブロックに分けて使用します。内訳は `rake console` の `memmap` コマンドで
確認できます。

**FM は ZF をバンクに分けたものです。** faRuby はバンク 3 を使い、スクリプトの
先頭で `FRSET(3)`、末尾で `FRSET(0)` に戻します。現在のバンクを読む命令が
無いため退避できません。**ラダーが 0 以外のバンクを使っている場合は壊します。**

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

アクセス幅を末尾で指定できます。既定は 16 ビット符号付きです。

| 表記 | 意味 | 占有 |
|------|------|------|
| `$DM100` | 16ビット符号付き | 1 ワード |
| `$DM100U` | 16ビット符号なし | 1 ワード |
| `$DM100L` | 32ビット符号付き | 2 ワード |
| `$DM100D` | 32ビット符号なし | 2 ワード |
| `$DM100F` | 単精度実数 | 2 ワード |

同じデバイスを異なる幅で参照すると領域が重なります。割り当ての管理は
プログラム作成者が行ってください。

**アンダースコアで区切ってもかまいません** (`$DM100_L`)。B は 16 進アドレスで
`D` と `F` が数字と重なるため、区切らないと `$B1F` は 0x1F と読まれます。
0x1 を実数で扱いたい場合は `$B1_F` と書きます。

**略記も使えます。** KV が受け付けるものと同じで、正式名に正規化されます。

| 略記 | 正式名 | デバイス |
|------|-------|---------|
| `$E100` | `$EM100` | 拡張データメモリ |
| `$D100` | `$DM100` | データメモリ |
| `$M100` | `$MR100` | 補助リレー |
| `$L100` | `$LR100` | ラッチリレー |

### ビットデバイスを整数として扱う

ビットデバイスに幅を付けると、そのビットから**連続したビット列**を整数として
読み書きします。チャンネル境界に揃っていなくてもかまいません。

```ruby
$MR[64] = true
$MR[65] = true
a = $MRL[64]      # 3 (下位2ビットが立つ)
$MRU[80] = 6      # MR501 と MR502 が ON
```

タイマとカウンタだけは意味が違い、幅を付けると**現在値**を返します
(`$T0D`)。幅によらず同じ値です。実数 (`$T0F`) は使えません。

### 実行時にアドレスを決める

`$DM100` のようにアドレスを書いた形はコンパイル時に確定します。実行時に計算した
アドレスへアクセスするには、アドレスを外して添字を付けます。

```ruby
i = 0
while i < 10
  $DM[600 + i] = 0
  i = i + 1
end
```

幅サフィックスも付けられます (`$DML[612]` は 32 ビット)。

**添字はデバイス番号です。** ワードデバイス (EM, DM, ZF) は表示上のアドレスと
一致しますが、MR / R / B は一致しません。MR400 は番号 64、B10 は 16 です。
番号空間では線形なので、MR415 の次は MR500 になります。

```ruby
$MR[64] = true    # MR400 を ON
```

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
- 組み込みメソッド (`!=` `!` `%` `abs` `to_i` `to_f` `floor` `round`)
- メソッドの定義と呼び出し (`def`、引数・再帰・`return`)
- `if` / `while` による分岐と繰り返し
- `nil` / `true` / `false` と整数の区別 (`if 0` は Ruby と同じく真)
- 実数 (単精度)。整数と混ざると Ruby と同じく実数になる
- グローバル変数と PLC デバイスの読み書き
- 実行時に決めたアドレスへのデバイスアクセス (`$DM[600 + i]`)
- 複数プログラムの並行実行 (既定 2 インスタンス)

整数は 32 ビット符号付き、実数は IEEE754 単精度です。

実数の 0 除算は Ruby と同じく `Infinity` を返しますが、**その値を演算に使うと
PLC が軽度エラーを出します**。0 除算が起こりうる箇所では除数を先に確かめて
ください。詳細は [doc/ruby_and_plc.md](doc/ruby_and_plc.md) を参照してください。

配列、文字列は未対応です。

### メソッドの定義と呼び出し

```ruby
def clamp(v)
  return 0 if v < 0
  v * 2
end
$DM100 = clamp(3)
```

引数・再帰・途中の `return`・メソッド内からのデバイスアクセスが動きます。
呼び出しの深さは `memory.max_frames` (既定 16) とレジスタ領域で決まり、
超えるとエラーで停止します。PLC はメモリが固定なので上限が要ります。

省略可能引数 (`def f(a, b = 1)`)、可変長引数、キーワード引数、ブロック付きの
呼び出し (`3.times do ... end`)、レシーバを書く呼び出し (`obj.foo`) は
未対応です。

組み込みメソッドは次の 8 個です。これ以外を呼ぶと実行時エラーで停止します。

| メソッド | 対象 | 備考 |
|---------|------|------|
| `!=` / `!` | すべて | `1 != 1.0` は偽、`nil != false` は真 |
| `%` | 整数 | 符号は除数に合う (`-7 % 3` は 2)。実数は未対応 |
| `abs` | 整数・実数 | 型は変わらない |
| `to_i` / `to_f` | 整数・実数 | `to_i` は 0 方向へ切り捨て |
| `floor` | 整数・実数 | −∞ 方向。`(-2.7).floor` は −3 |
| `round` | 整数・実数 | 0 から遠い方へ丸める。`2.5.round` は 3 |

## ドキュメント

| 文書 | 内容 |
|------|------|
| [doc/architecture.md](doc/architecture.md) | VM の仕組み、メモリ配置、コード生成 |
| [doc/roadmap.md](doc/roadmap.md) | 何を作るかと、なぜその順序なのか |
| [doc/method_calls.md](doc/method_calls.md) | メソッド定義・呼び出しの設計と実装の記録 |
| [doc/blocks.md](doc/blocks.md) | ブロックの設計メモ (未実装) |
| [doc/ruby_and_plc.md](doc/ruby_and_plc.md) | Ruby と PLC で意味が違う箇所とその埋め方。新しい機種に対応する際の確認項目 |
| [doc/plc_devices.md](doc/plc_devices.md) | デバイスの種類とアクセス幅 |
| [doc/opcodes.md](doc/opcodes.md) | 対応オペコード一覧 |
| [doc/plc_access_issues.md](doc/plc_access_issues.md) | plc_access で見つかった問題の控え |

## ライセンス

MIT License
