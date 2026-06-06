# mruby/c on PLC

PLC 上で Ruby (mruby/c) を動作させる実験的プロジェクトです。

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
mrubycOnPlc/
├── tools/          PC側ツール (Ruby)
├── simulator/      PC側 VM シミュレータ
├── plc/keyence/    KV スクリプト VM
├── test/           テスト
└── doc/            ドキュメント
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

`mrubycOnPlc.yml.example` をコピーして、環境に合わせて編集してください。

```bash
cp mrubycOnPlc.yml.example mrubycOnPlc.yml
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
| `load <file.mrb>` | バイトコードを PLC に転送 |
| `run` | VM 実行開始 |
| `status` | VM 状態を表示 |
| `regs [count]` | レジスタ値を表示 |
| `stop` | VM 停止 |
| `reset` | VM リセット要求を送信 |
| `verify` | PLC メモリとバイナリを比較 |
| `disasm <file.mrb>` | バイトコード逆アセンブル表示 |
| `sim <file.mrb>` | PC 上のシミュレータで実行 |
| `connect` | PLC 接続確認 |
| `help` | コマンド一覧 |
| `quit` | 終了 |

### 使用例

```
mrubycOnPlc> compile test.rb
mrubycOnPlc> load
mrubycOnPlc> verify
mrubycOnPlc> run
mrubycOnPlc> status
mrubycOnPlc> regs
```

### テストの実行

```bash
rake test
```

## 現在のマイルストーン

### マイルストーン 1: 整数四則演算

- 整数のロード、加減乗除、変数代入が動作する最小 VM
- 対象: `a = 1 + 2; b = a * 3` のような単純な計算

詳細は [doc/architecture.md](doc/architecture.md) を参照してください。

## ライセンス

MIT License
