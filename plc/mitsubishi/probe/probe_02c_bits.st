(* faRuby probe 2c: ビット。説明は README.md *)

(* 20 *)
M100 := TRUE;
D250 := 0;
IF M100 THEN
  D250 := 1;
END_IF;

(* 21 *)
D264 := 0;
D264.0 := TRUE;
D252 := 0;
IF D264.0 THEN
  D252 := 1;
END_IF;

(* 22 は構文エラー。ビット指定とインデックス修飾は併せられない
 *   D260Z2.1 := TRUE;
 *
 * 23 代わりに読んで直して書く (KV と同じ手) *)
Z2 := 4;
D260Z2 := 0;
D260Z2 := D260Z2 OR 2;
D254 := 0;
IF D264.1 THEN
  D254 := 1;
END_IF;
