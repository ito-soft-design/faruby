# programs

**PLC で動かす Ruby プログラムの置き場です。**

```
$ rake console
faruby> compile blink.rb
faruby> load
faruby> run
```

**コンソールはここを探すので、ファイル名だけで足ります。**

デバイスの割り付け表もここに置きます。プログラムの先頭 1 行で指します。

```ruby
# devices: blink.devices.rb
```
