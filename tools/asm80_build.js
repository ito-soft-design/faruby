// asm80 で .a80 を組み立てる (.include 付き)
//
// **npm の asm80 (0.9.3) の CLI は `.include` を扱えません。** 取り込みには
// `ASM.fileGet()` で読み取り関数を登録する必要がありますが、`asm80.js` が
// それを登録しないため `fileGet is not a function` で落ちます。しかも
// エラー表示の側も `e.s.numline` を読もうとして落ちるので、何行目かも
// 出ません。
//
// ここでは asm80.js と同じ手順を踏み、**取り込みだけ自分で繋ぎます。**
// 出力は本体と同じ (.hex と .lst を元ファイルの隣へ)。
//
//   node tools/asm80_build.js <.a80 のパス> [asm80 パッケージの場所]
//
// パッケージの場所を省いたときは、`require` の探索と npm のグローバル領域を
// 順に見ます。

const fs = require("fs");
const path = require("path");

// asm80 パッケージの場所
//
// **`npm prefix -g` は呼びません。** Windows では npm が npm.cmd なので
// spawnSync が ENOENT になります。置き場を順に見るだけにします。
function packageDir(given) {
  if (given) return given;
  if (process.env.ASM80_PATH) return process.env.ASM80_PATH;

  // プロジェクトに入れている場合
  try {
    return path.dirname(require.resolve("asm80/asm80.js"));
  } catch (e) {
    // グローバルを見る
  }

  const home = process.env.USERPROFILE || process.env.HOME || "";
  const candidates = [
    process.env.APPDATA && path.join(process.env.APPDATA, "npm", "node_modules", "asm80"),
    "/usr/local/lib/node_modules/asm80",
    "/usr/lib/node_modules/asm80",
    home && path.join(home, ".npm-global", "lib", "node_modules", "asm80"),
    home && path.join(home, ".nvm", "versions"),
  ].filter(Boolean);

  const found = candidates.find((c) => fs.existsSync(path.join(c, "asm.js")));
  if (found) return found;

  console.error(
    "asm80 が見つかりません。`npm install -g asm80` を実行するか、" +
      "ASM80_PATH でパッケージの場所を指してください"
  );
  process.exit(1);
}

const src = process.argv[2];
if (!src) {
  console.error("使い方: node tools/asm80_build.js <.a80> [asm80 のパス]");
  process.exit(1);
}

const pkg = packageDir(process.argv[3]);
const ASM = require(path.join(pkg, "asm.js"));
const Monolith = require(path.join(pkg, "monolith.js"));

const srcDir = path.dirname(path.resolve(src));

// **取り込みは元ファイルと同じディレクトリから読みます。**
//
// 名前は `.include "vm_constants.a80"` の引用符込みで渡ってくるので外します。
ASM.fileGet(function (name) {
  const file = String(name).trim().replace(/^["']|["']$/g, "");
  return fs.readFileSync(path.join(srcDir, file), "utf8");
});

const data = fs.readFileSync(src, "utf8");
const result = ASM.compile(data, Monolith.I8080);

if (result[0]) {
  const e = result[0];
  // **自分で出します。** 本体は e.s.numline を読んで落ちる
  const where = e.s && e.s.numline ? ` (${e.s.numline} 行目)` : "";
  console.error(`アセンブルエラー${where}: ${e.msg || e.message}`);
  if (e.s && e.s.line) console.error(`  ${e.s.line}`);
  process.exit(1);
}

const out = result[1];
const base = path.resolve(src).replace(/\.a80$/i, "");
fs.writeFileSync(`${base}.hex`, ASM.hex(out[0]));
fs.writeFileSync(`${base}.lst`, ASM.lst(out[0], out[1]));
console.log(`アセンブル完了: ${path.basename(base)}.hex`);
