Output docs/demo/formats.gif
Set Height 420
Source docs/demo/setup.tape

Type `stury --to csv 'select(.country == "NO") | {city, population}' cities.csv`
Sleep 400ms
Enter
Sleep 2s

Type `stury -c '.server | {port, type: (.started | .@tag)}' server.toml`
Sleep 400ms
Enter
Sleep 2s

Type `stury --to yaml . server.toml`
Sleep 400ms
Enter
Sleep 2s

Type `stury -c '.feed.entry | {id: .&id, ns: .@namespace, title}' feed.xml`
Sleep 400ms
Enter
Sleep 2s

Type `stury -c '[css("a.story") | .&href]' page.html`
Sleep 400ms
Enter
Sleep 2s
Sleep 2s
