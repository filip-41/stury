Output docs/demo/schema.gif
Set Height 508
Source docs/demo/setup.tape

Type `stury check --schema user.schema.json users.ndjson`
Sleep 400ms
Enter
Sleep 2s

Type `stury check -c --filter '.nmae' --schema user.schema.json`
Sleep 400ms
Enter
Sleep 2s

Type `stury schema sample --count 2 --seed 1 user.schema.json`
Sleep 400ms
Enter
Sleep 2s

Type `stury schema gen user.schema.json | sed -n '/^Root/,/^}/p'`
Sleep 400ms
Enter
Sleep 2s
Sleep 2s
